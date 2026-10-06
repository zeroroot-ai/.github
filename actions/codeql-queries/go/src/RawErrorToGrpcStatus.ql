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

/**
 * A server interface of a gRPC service: an interface type that
 * protoc-gen-go-grpc declares in a `_grpc.pb.go` file, with a name that
 * ends in `Server`.
 */
class GrpcServerInterface extends DefinedType {
  GrpcServerInterface() {
    this.getUnderlyingType() instanceof InterfaceType and
    this.getName().matches("%Server") and
    this.getEntity().getDeclaration().getFile().getBaseName().matches("%\\_grpc.pb.go")
  }
}

/**
 * A gRPC handler: a method, outside generated code, whose receiver type
 * implements a gRPC server interface, and whose name is a method of that
 * interface. A helper function, a library method and a generated client
 * method are not handlers.
 */
class GrpcHandler extends FuncDecl {
  GrpcHandler() {
    not this.getFile().getBaseName().matches("%.pb.go") and
    exists(Method m, GrpcServerInterface srv, Type recv |
      m = this.getFunction() and
      recv = m.getReceiverType() and
      (
        recv.implements(srv.getUnderlyingType()) or
        recv.getPointerType().implements(srv.getUnderlyingType())
      ) and
      exists(srv.getMethod(m.getName()))
    )
  }
}

/**
 * Flow from a coded-error constructor to an error that a handler returns.
 * The flow crosses calls, so an error that a helper coded, or a
 * package-level coded error, is not a raw error.
 */
module CodedErrorConfig implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node n) { n instanceof CodedErrorCall }

  predicate isSink(DataFlow::Node n) {
    exists(GrpcHandler h, ReturnStmt ret |
      ret.getEnclosingFunction() = h and
      n = DataFlow::exprNode(ret.getExpr(1))
    )
  }
}

module CodedErrorFlow = DataFlow::Global<CodedErrorConfig>;

from GrpcHandler handler, ReturnStmt ret, Expr errExpr
where
  handler.getType().getNumResult() = 2 and
  handler.getType().getResultType(1).getName() = "error" and
  ret.getEnclosingFunction() = handler and
  errExpr = ret.getExpr(1) and
  // The error is a variable, not a literal nil and not a wrapping call...
  errExpr instanceof Ident and
  not errExpr.toString() = "nil" and
  // ...and no coded-error constructor reaches it, in this function or in a
  // function that it calls.
  not CodedErrorFlow::flowTo(DataFlow::exprNode(errExpr)) and
  // ...and it does not come from a call through a function value. The
  // query cannot see which function that value names, so it cannot know
  // whether the error carries a code.
  not exists(DataFlow::CallNode c |
    not exists(c.getTarget()) and
    DataFlow::localFlow(c.getAResult(), DataFlow::exprNode(errExpr))
  )
select ret,
  "$@ returns a raw error; wrap via connect.NewError or status.Error to set the gRPC code",
  handler, handler.getName()
