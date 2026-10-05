/**
 * @name dangerouslySetInnerHTML without sanitizer
 * @description Non-constant content reaching dangerouslySetInnerHTML
 *   must pass through DOMPurify (or equivalent). Per slice 4.5 of the
 *   zeroroot-ai production-readiness epic.
 * @kind problem
 * @id zeroroot-ai/xss-without-sanitize
 * @problem.severity error
 * @security-severity 8.5
 * @precision medium
 * @tags security
 *       external/cwe/cwe-079
 */

import javascript

/** The expression that becomes the HTML: `x` in `dangerouslySetInnerHTML={{ __html: x }}`. */
Expr htmlOf(JsxAttribute attr) {
  attr.getName() = "dangerouslySetInnerHTML" and
  (
    result = attr.getValue().(ObjectExpr).getPropertyByName("__html").getInit()
    or
    not attr.getValue() instanceof ObjectExpr and result = attr.getValue()
  )
}

/** A sanitizer call: `DOMPurify.sanitize(x)`, `sanitize(x)`, `sanitizeHtml(x)`. */
class SanitizeCall extends DataFlow::CallNode {
  SanitizeCall() { this.getCalleeName() = ["sanitize", "sanitizeHtml"] }
}

from JsxAttribute attr, Expr html
where
  html = htmlOf(attr) and
  // A string constant is not an injection vector.
  not exists(html.getStringValue()) and
  // Sanitized content is fine wherever the sanitizer call happened.
  not exists(SanitizeCall s | s.flowsToExpr(html))
select attr, "dangerouslySetInnerHTML receives content that did not pass through a sanitizer"
