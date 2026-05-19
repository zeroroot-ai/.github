// Commitlint config — Conventional Commits.
// Slice 2.6 of the production-readiness epic.
//
// Per-repo file: commitlint.config.js at repo root, contents identical
// to this template. Drift detector asserts the file matches.
module.exports = {
  extends: ["@commitlint/config-conventional"],
  rules: {
    // Subject (the text after "type(scope):") must NOT start with uppercase.
    // Catches PRs like `feat: AST-driven X` that pr-title-lint rejects.
    "subject-case": [2, "always", "lower-case"],
    // Body lines unbounded — long PRs need long bodies.
    "body-max-line-length": [0],
    "footer-max-line-length": [0],
  },
};
