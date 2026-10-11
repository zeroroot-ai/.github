/**
 * @name session token sent to the client
 * @description A session token, a cookie value or an auth header that
 *   flows from server code into a value the client receives: a prop of
 *   a `"use client"` component, a serialized page prop, or a response
 *   body. The client can read it, and so can any script on the page.
 * @kind problem
 * @id zeroroot-ai/session-token-to-client
 * @problem.severity error
 * @security-severity 7.5
 * @precision medium
 * @tags security
 *       external/cwe/cwe-200
 *       external/cwe/cwe-522
 */

import javascript
import ClientBoundary

/** Request header names that carry a credential. */
private string credentialHeader() {
  result = ["authorization", "proxy-authorization", "cookie", "x-api-key", "x-auth-token"]
}

/** The cookie store from `cookies()` in `next/headers`, awaited or not. */
private API::Node nextCookieStore() {
  result = API::moduleImport("next/headers").getMember("cookies").getReturn() or
  result = API::moduleImport("next/headers").getMember("cookies").getReturn().getPromised()
}

/** The header store from `headers()` in `next/headers`, awaited or not. */
private API::Node nextHeaderStore() {
  result = API::moduleImport("next/headers").getMember("headers").getReturn() or
  result = API::moduleImport("next/headers").getMember("headers").getReturn().getPromised()
}

/** A property read on a request object: `req.cookies`, `request.headers`. */
private DataFlow::PropRead requestRead(string name) {
  result.getPropertyName() = name and
  result.getBase().asExpr().(VarAccess).getName() = ["req", "request"]
}

/** A cookie value: `cookies().get(x)`, `req.cookies.get(x)`, `req.cookies`. */
predicate cookieValue(DataFlow::Node n) {
  n = nextCookieStore().getMember(["get", "getAll"]).getACall()
  or
  n = requestRead("cookies").getAMethodCall(["get", "getAll"])
  or
  n = requestRead("cookies")
}

/** A credential header: `headers().get("authorization")`, `req.headers.authorization`. */
predicate authHeader(DataFlow::Node n) {
  exists(DataFlow::CallNode get |
    get = nextHeaderStore().getMember("get").getACall() or
    get = requestRead("headers").getAMethodCall("get")
  |
    get.getArgument(0).getStringValue().toLowerCase() = credentialHeader() and
    n = get
  )
  or
  exists(DataFlow::PropRead r |
    r = requestRead("headers").getAPropertyRead() and
    r.getPropertyName().toLowerCase() = credentialHeader() and
    n = r
  )
}

/**
 * Holds if the property name `name` says that its value is a session token.
 * A read of such a name is a source.
 *
 * Accepted gap: an id such as `sessionId` is not a source, because it names a
 * record, for example an agent run session (dashboard#278). A server session
 * id that authenticates is still found when it comes from a cookie or a
 * credential header, but not when the code reads it off a server session
 * object as `session.sessionId`.
 */
bindingset[name]
private predicate credentialName(string name) {
  name.regexpMatch("(?i)(session|access|refresh|id|auth|bearer|csrf|api)[_-]?token|jwt")
}

/**
 * Holds if the property name `name` may hold a credential. It is wider than
 * `credentialName`: it is not a source, it only keeps the taint through a
 * field read in `nonCredentialField`.
 */
bindingset[name]
private predicate mayHoldCredential(string name) {
  credentialName(name) or
  name.regexpMatch("(?i).*(token|jwt|secret|passw(or)?d|credential|cookie|bearer|signature).*|(?i)(s?id|key|api[_-]?key|auth|session)")
}

/** A property read whose name says it holds a session token. */
predicate sessionTokenRead(DataFlow::Node n) {
  credentialName(n.(DataFlow::PropRead).getPropertyName())
}

/** Holds if `n` is a cookie value or a credential header. */
private predicate credentialSource(DataFlow::Node n) { cookieValue(n) or authHeader(n) }

/**
 * Holds if `n` reads a field out of the result of a call, the decode of a
 * cookie or a credential header, and the field name says nothing about a
 * credential: the `attemptId` of a decoded signup cookie. The field is not
 * the value that authenticates, so the taint stops there.
 *
 * The taint goes on through each other read: a read that is itself a cookie
 * value (`req.cookies`), a read on a cookie store (`req.cookies.session`), the
 * `value` of a cookie entry, an index read (`parts[0]`), a read on an object
 * literal (`box.t`), and a field whose name may hold a credential
 * (`JSON.parse(raw).token`).
 */
predicate nonCredentialField(DataFlow::PropRead n) {
  exists(string name | name = n.getPropertyName() |
    name.regexpMatch("[A-Za-z_$][A-Za-z0-9_$]*") and
    name != "value" and
    not mayHoldCredential(name)
  ) and
  not credentialSource(n) and
  n.getBase().getALocalSource() instanceof DataFlow::CallNode and
  not credentialSource(n.getBase().getALocalSource())
}

module SessionTokenToClientConfig implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node n) { credentialSource(n) or sessionTokenRead(n) }

  predicate isBarrier(DataFlow::Node n) { nonCredentialField(n) }

  predicate isSink(DataFlow::Node n) { clientVisible(n, _) }
}

module SessionTokenToClient = TaintTracking::Global<SessionTokenToClientConfig>;

from DataFlow::Node source, DataFlow::Node sink
where SessionTokenToClient::flow(source, sink)
select sink, "A session token from $@ reaches the client here.", source, source.toString()
