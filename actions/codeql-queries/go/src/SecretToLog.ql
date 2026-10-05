/**
 * @name Secret material flowing to log
 * @description Detects when secret-source values (vault.Read,
 *   zitadel client output, FGA admin output) reach log/printf sinks.
 *   Per slice 4.3 of the zeroroot-ai production-readiness epic.
 * @kind problem
 * @id zeroroot-ai/secret-to-log
 * @problem.severity error
 * @security-severity 8.0
 * @precision medium
 * @tags security
 *       external/cwe/cwe-532
 */

import go
import semmle.go.dataflow.TaintTracking

class SecretSource extends DataFlow::Node {
  SecretSource() {
    // Vault SDK reads
    exists(DataFlow::CallNode c |
      c.getTarget().getQualifiedName().regexpMatch(".*vault.*\\.(Read|KV.*\\.Get|Logical.*\\.Read)") and
      this = c.getResult()
    )
    or
    // Generic "secret"-named return values from auth-shaped functions
    exists(Function f |
      f.getName().regexpMatch("(?i).*(secret|token|password|credential|apikey).*") and
      this = f.getACall().getAResult()
    )
  }
}

class LogSink extends DataFlow::Node {
  LogSink() {
    exists(DataFlow::CallNode c |
      c.getTarget().getQualifiedName().regexpMatch(".*(log|slog)\\..*Print.*|.*log\\.(Info|Warn|Error|Debug|Print).*") and
      this = c.getAnArgument()
    )
    or
    exists(DataFlow::CallNode c |
      c.getTarget().getQualifiedName() = "fmt.Printf" and
      this = c.getAnArgument()
    )
  }
}

module SecretToLogConfig implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node n) { n instanceof SecretSource }
  predicate isSink(DataFlow::Node n) { n instanceof LogSink }
}

module SecretToLogFlow = TaintTracking::Global<SecretToLogConfig>;

// A `problem` query, not a `path-problem` query. The test of a path query
// prints the row number of each library model on the path, and that number
// changes with each CodeQL release. So the expected result needed a new pin
// after a change that touched no query.
from DataFlow::Node source, DataFlow::Node sink
where SecretToLogFlow::flow(source, sink)
select sink, "secret material from $@ reaches log sink", source, "vault/secret source"
