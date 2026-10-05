/**
 * The server/client trust boundary of a Next.js application.
 *
 * A server value crosses to the client through one of three places:
 *
 * 1. a prop of a component defined in a `"use client"` module,
 * 2. the `props` object that `getServerSideProps` or `getStaticProps`
 *    returns, which Next.js serializes into the page, or
 * 3. an HTTP response body.
 *
 * A value that is stored in an object literal that crosses also crosses.
 * `clientVisible` names every such value, so a flow query can use it as
 * its sink set.
 */

import javascript

/** Holds if the prologue of module `m` holds the `"use client"` directive. */
predicate isClientModule(Module m) {
  exists(Directive::UseClientDirective d | d.getContainer() = m)
}

/** Holds if a `"use client"` module defines the React component `c`. */
predicate isClientComponent(ReactComponent c) { isClientModule(c.getTopLevel()) }

/** Holds if `n` becomes a prop of a client component, in JSX or in `createElement`. */
predicate clientComponentProp(DataFlow::Node n) {
  exists(ReactComponent c | isClientComponent(c) |
    n = c.getACandidatePropsValue(_)
    or
    n = c.getACandidatePropsSource()
  )
  or
  exists(ReactComponent c, JsxElement e, JsxSpreadAttribute spread |
    isClientComponent(c) and
    c.getAComponentCreatorReference().flowsToExpr(e.getNameExpr()) and
    spread = e.getAnAttribute() and
    n = DataFlow::valueNode(spread.getValue().getOperand())
  )
}

/**
 * Holds if `n` is the `props` value that a Next.js data function
 * (`getServerSideProps`, `getStaticProps`) returns. Next.js serializes it
 * into the page HTML.
 */
predicate serializedPageProps(DataFlow::Node n) {
  exists(DataFlow::FunctionNode f |
    f =
      any(Module m).getAnExportedValue(["getServerSideProps", "getStaticProps"]).getAFunctionValue()
  |
    n = f.getAReturn().getALocalSource().getAPropertyWrite("props").getRhs()
  )
}

/** Holds if `n` is sent as an HTTP response body. */
predicate responseBody(DataFlow::Node n) {
  n instanceof Http::ResponseSendArgument
  or
  // NextResponse.json(x), new NextResponse(x)
  exists(API::Node response |
    response = API::moduleImport("next/server").getMember("NextResponse")
  |
    n = response.getMember("json").getACall().getArgument(0)
    or
    n = response.getAnInstantiation().getArgument(0)
  )
  or
  // Response.json(x), new Response(x)
  exists(DataFlow::SourceNode response | response = DataFlow::globalVarRef("Response") |
    n = response.getAMemberCall("json").getArgument(0)
    or
    n = response.getAnInstantiation().getArgument(0)
  )
  or
  // res.json(x), res.send(x), res.end(x), res.write(x) on a response parameter
  exists(DataFlow::MethodCallNode c |
    c.getMethodName() = ["json", "send", "end", "write"] and
    c.getReceiver().asExpr().(VarAccess).getName() = ["res", "response"] and
    n = c.getArgument(0)
  )
}

/** Holds if the value of `n` leaves the server. */
predicate crossesToClient(DataFlow::Node n) {
  clientComponentProp(n) or serializedPageProps(n) or responseBody(n)
}

/** An object literal whose properties cross to the client together with `crossing`. */
private DataFlow::ObjectLiteralNode crossingObject(DataFlow::Node crossing) {
  crossesToClient(crossing) and
  (
    result.flowsTo(crossing)
    or
    result.flowsTo(crossingObject(crossing).getAPropertyWrite().getRhs())
  )
}

/**
 * Holds if `n` becomes visible to the client at `crossing`: `n` is the
 * crossing value itself, or a property value of an object literal that
 * crosses there.
 */
predicate clientVisible(DataFlow::Node n, DataFlow::Node crossing) {
  crossesToClient(crossing) and
  (
    n = crossing
    or
    n = crossingObject(crossing).getAPropertyWrite().getRhs()
  )
}
