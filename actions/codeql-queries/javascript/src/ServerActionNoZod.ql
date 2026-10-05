/**
 * @name req.body consumed without zod validation
 * @description A `req.body` read that reaches no zod parse call
 *   (`parse`, `safeParse`, `parseAsync`, `safeParseAsync`) on any
 *   data-flow path is consumed unvalidated. Per slice 4.5.
 * @kind problem
 * @id zeroroot-ai/server-action-no-zod
 * @problem.severity warning
 * @security-severity 6.5
 * @precision medium
 * @tags security
 *       external/cwe/cwe-020
 */

import javascript

/** Holds if `r` reads `req.body` or `request.body`. */
predicate bodyRead(DataFlow::PropRead r) {
  r.getPropertyName() = "body" and
  r.getBase().asExpr().(VarAccess).getName() = ["req", "request"]
}

/** Holds if `n` is an argument of a zod-style parse call: `Schema.parse(x)` and its safe and async forms. */
predicate zodParseArgument(DataFlow::Node n) {
  exists(DataFlow::MethodCallNode c |
    c.getMethodName() = ["parse", "safeParse", "parseAsync", "safeParseAsync"] and
    n = c.getAnArgument()
  )
}

module BodyToZodConfig implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node n) { bodyRead(n) }

  predicate isSink(DataFlow::Node n) { zodParseArgument(n) }
}

module BodyToZod = DataFlow::Global<BodyToZodConfig>;

from DataFlow::PropRead body
where
  bodyRead(body) and
  not exists(DataFlow::Node sink | BodyToZod::flow(body, sink))
select body, "req.body is consumed without a zod parse on any path from this read"
