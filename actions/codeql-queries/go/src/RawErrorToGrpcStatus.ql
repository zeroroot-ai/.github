/**
 * @name Raw error returned from gRPC handler
 * @description gRPC handlers must wrap errors in connect.NewError or
 *   status.Error to set the appropriate code. Bare error returns
 *   produce code Unknown which leaks internal detail to the caller.
 *   Per slice 4.4 of the zeroroot-ai production-readiness epic.
 * @kind problem
 * @id zeroroot-ai/raw-error-to-grpc-status
 * @problem.severity warning
 * @precision medium
 * @tags maintainability
 *       reliability
 */

import go

/**
 * A call that produces an error carrying a gRPC or Connect code:
 * `status.Error`, `status.Errorf`, `status.New(...).Err()`, `st.Err()`,
 * `connect.NewError` and `connect.NewWireError`.
 */
class CodedErrorCall extends DataFlow::CallNode {
  CodedErrorCall() {
    exists(string pkg | pkg = ["google.golang.org/grpc/status", "google.golang.org/grpc/internal/status"] |
      this.getTarget().hasQualifiedName(pkg, ["Error", "Errorf"])
      or
      this.getTarget().(Method).hasQualifiedName(pkg, "Status", "Err")
    )
    or
    this.getTarget()
        .hasQualifiedName(["connectrpc.com/connect", "github.com/bufbuild/connect-go"],
          ["NewError", "NewWireError"])
  }
}

from FuncDecl handler, ReturnStmt ret, Expr errExpr
where
  // Heuristic: handler returns (*pb.X, error), the typical gRPC handler shape
  handler.getName().regexpMatch("[A-Z][a-zA-Z]+") and
  handler.getType().getNumResult() = 2 and
  handler.getType().getResultType(1).getName() = "error" and
  ret.getEnclosingFunction() = handler and
  errExpr = ret.getExpr(1) and
  // The error is a variable, not a literal nil and not a wrapping call...
  errExpr instanceof Ident and
  not errExpr.toString() = "nil" and
  // ...and nothing that reaches it was produced by a coded-error constructor.
  not exists(CodedErrorCall c | DataFlow::localFlow(c, DataFlow::exprNode(errExpr)))
select ret,
  "$@ returns a raw error; wrap via connect.NewError or status.Error to set the gRPC code",
  handler, handler.getName()
