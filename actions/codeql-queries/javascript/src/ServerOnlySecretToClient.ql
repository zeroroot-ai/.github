/**
 * @name server-only secret sent to the client
 * @description A value read from `process.env` or from a module that
 *   imports `server-only` flows into a value the client receives: a
 *   prop of a `"use client"` component, a serialized page prop, or a
 *   response body. `NEXT_PUBLIC_*` variables and `NODE_ENV` are public
 *   by contract and do not count.
 * @kind problem
 * @id zeroroot-ai/server-only-secret-to-client
 * @problem.severity error
 * @security-severity 7.5
 * @precision medium
 * @tags security
 *       external/cwe/cwe-200
 *       external/cwe/cwe-497
 */

import javascript
import ClientBoundary

/** The `process.env` object. */
private DataFlow::SourceNode processEnv() { result = NodeJSLib::process().getAPropertyRead("env") }

/** Holds if `n` reads the environment variable `name` from `process.env`. */
private predicate envRead(DataFlow::PropRead n, string name) {
  n = processEnv().getAPropertyRead() and
  name = n.getPropertyName()
}

/** Holds if Next.js ships the variable `name` to the browser by contract. */
bindingset[name]
private predicate publicVariable(string name) { name.matches("NEXT_PUBLIC_%") or name = "NODE_ENV" }

/** Holds if the prologue of module `m` imports `server-only`. */
predicate isServerOnlyModule(Module m) {
  exists(Import i | i.getTopLevel() = m and i.getImportedPathString() = "server-only")
}

/**
 * Holds if `n` is a whole object that crosses as one value: no property of
 * this occurrence is read. When a property is read, that read is the source,
 * so one leak gives one result.
 */
private predicate wholeObject(DataFlow::SourceNode n) { not exists(n.getAPropertyRead()) }

/** A binding imported from a module that imports `server-only`. */
predicate serverOnlyImport(DataFlow::Node n) {
  exists(Import i, DataFlow::SourceNode mod |
    isServerOnlyModule(i.getImportedModule()) and mod = i.getImportedModuleNode()
  |
    n = mod and wholeObject(mod)
    or
    n = mod.getAPropertyRead()
  )
}

module ServerOnlySecretToClientConfig implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node n) {
    n = processEnv() and wholeObject(n)
    or
    exists(string name | envRead(n, name) and not publicVariable(name))
    or
    serverOnlyImport(n)
  }

  predicate isBarrier(DataFlow::Node n) {
    exists(string name | envRead(n, name) and publicVariable(name))
  }

  predicate isSink(DataFlow::Node n) { clientVisible(n, _) }
}

module ServerOnlySecretToClient = TaintTracking::Global<ServerOnlySecretToClientConfig>;

from DataFlow::Node source, DataFlow::Node sink
where ServerOnlySecretToClient::flow(source, sink)
select sink, "A server-only value from $@ reaches the client here.", source, source.toString()
