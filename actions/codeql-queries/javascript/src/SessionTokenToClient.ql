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

/** A property read whose name says it holds a session token. */
predicate sessionTokenRead(DataFlow::Node n) {
  n.(DataFlow::PropRead)
      .getPropertyName()
      .regexpMatch("(?i)(session|access|refresh|id|auth|bearer|csrf|api)[_-]?token|jwt|session[_-]?id")
}

module SessionTokenToClientConfig implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node n) { cookieValue(n) or authHeader(n) or sessionTokenRead(n) }

  predicate isSink(DataFlow::Node n) { clientVisible(n, _) }
}

module SessionTokenToClient = TaintTracking::Global<SessionTokenToClientConfig>;

from DataFlow::Node source, DataFlow::Node sink
where SessionTokenToClient::flow(source, sink)
select sink, "A session token from $@ reaches the client here.", source, source.toString()
