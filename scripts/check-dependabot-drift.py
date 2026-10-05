#!/usr/bin/env python3
"""Compare the dependabot.yml of each repo with the rules of the template.

The rule (owner decision of 2026-10-05, D44): Dependabot opens grouped pull
requests each week. A patch or minor update is in one group and merges alone
on a green merge gate. A major update opens as its own pull request and waits
for a person. templates/dependabot.yml is the form.

RULES FOR ONE `updates` ENTRY

  weekly          schedule.interval is weekly.
  prefix          commit-message.prefix is chore(deps).
  group           one group has the pattern "*" and exactly the update types
                  minor and patch.
  major-in-group  no group holds a major update. The one exception is the
                  group `codeql-action`, whose patterns all start with
                  github/codeql-action.
  ignore-major    no ignore rule for "*" removes major updates. A major
                  update must open.
  ignore:<name>   an ignore rule for one dependency is a named difference.

RULES FOR ONE REPO

  missing-file    the repo has a dependency manifest and no dependabot.yml.
  missing-entry   the repo has a manifest of an ecosystem (go.mod,
                  package.json, a Dockerfile, a workflow) and no entry for it.

A difference passes only with an entry in
repo-settings/dependabot-exceptions.json that names the repo, the ecosystem,
the rule and a reason. An entry that exempts no finding is a finding.

USAGE

  READ_TOKEN=<token> python3 scripts/check-dependabot-drift.py
  python3 scripts/check-dependabot-drift.py --selftest

Exit codes: 0 clean, 1 a finding, 2 setup error.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys

import yaml

ORG = "zeroroot-ai"
ROOT = pathlib.Path(__file__).resolve().parent.parent
EXCEPTIONS = ROOT / "repo-settings" / "dependabot-exceptions.json"
MINOR_PATCH = {"minor", "patch"}
MANIFESTS = (
    ("gomod", re.compile(r"(^|/)go\.mod$")),
    ("npm", re.compile(r"(^|/)package\.json$")),
    ("docker", re.compile(r"(^|/)Dockerfile[^/]*$")),
    ("github-actions", re.compile(r"^\.github/workflows/[^/]+\.ya?ml$")),
)
SKIP_PATH = re.compile(r"(^|/)(node_modules|vendor|testdata|tests?/fixtures|\.worktrees)/")


def ecosystems_of(paths: list[str]) -> set[str]:
    found = set()
    for path in paths:
        if SKIP_PATH.search(path):
            continue
        for name, pattern in MANIFESTS:
            if pattern.search(path):
                found.add(name)
    return found


def check_entry(entry: dict) -> list[str]:
    """Return the rule ids that one `updates` entry breaks."""
    broken = []
    if (entry.get("schedule") or {}).get("interval") != "weekly":
        broken.append("weekly")
    if (entry.get("commit-message") or {}).get("prefix") != "chore(deps)":
        broken.append("prefix")
    groups = entry.get("groups") or {}
    has_group = False
    for name, group in groups.items():
        group = group or {}
        types = set(group.get("update-types") or [])
        patterns = group.get("patterns") or []
        if types == MINOR_PATCH:
            if "*" in patterns:
                has_group = True
            continue
        codeql = name == "codeql-action" and patterns and all(
            str(p).startswith("github/codeql-action") for p in patterns)
        if not codeql:
            broken.append("major-in-group")
    if not has_group:
        broken.append("group")
    for rule in entry.get("ignore") or []:
        name = rule.get("dependency-name", "")
        types = rule.get("update-types") or []
        if name == "*":
            if not types or any("semver-major" in t for t in types):
                broken.append("ignore-major")
        else:
            broken.append(f"ignore:{name}")
    return sorted(set(broken))


def check_repo(repo: str, paths: list[str], config_text: str | None) -> list[tuple[str, str, str]]:
    """Return the findings of one repo as (repo, ecosystem, rule)."""
    needed = ecosystems_of(paths)
    if config_text is None:
        return [(repo, eco, "missing-file") for eco in sorted(needed)]
    try:
        config = yaml.safe_load(config_text) or {}
    except yaml.YAMLError:
        return [(repo, "*", "not-yaml")]
    findings = []
    seen = set()
    for entry in config.get("updates") or []:
        eco = entry.get("package-ecosystem", "?")
        seen.add(eco)
        findings += [(repo, eco, rule) for rule in check_entry(entry)]
    findings += [(repo, eco, "missing-entry") for eco in sorted(needed - seen)]
    return sorted(set(findings))


def apply_exceptions(findings: list[tuple[str, str, str]], exceptions: list[dict]) -> tuple[list[str], int]:
    """Return (messages of what is left, number of exempt findings)."""
    used = set()
    left = []
    exempt = 0
    for repo, eco, rule in findings:
        match = next((i for i, e in enumerate(exceptions)
                      if e.get("repo") == repo and e.get("ecosystem") == eco and e.get("rule") == rule), None)
        if match is None:
            left.append(f"{repo}: {eco}: {rule}")
        else:
            used.add(match)
            exempt += 1
    for i, e in enumerate(exceptions):
        if not str(e.get("reason", "")).strip():
            left.append(f"exception {e.get('repo')}/{e.get('ecosystem')}/{e.get('rule')} has no reason")
        if i not in used:
            left.append(f"exception {e.get('repo')}/{e.get('ecosystem')}/{e.get('rule')} exempts no finding. Remove it.")
    return left, exempt


# --- GitHub ------------------------------------------------------------------

def gh(args: list[str], token: str) -> tuple[int, str]:
    p = subprocess.run(["gh", *args], capture_output=True, text=True,
                       env=dict(os.environ, GH_TOKEN=token), check=False)
    return p.returncode, p.stdout


def read_org(token: str) -> list[tuple[str, list[str], str | None]]:
    code, out = gh(["api", "--paginate", f"orgs/{ORG}/repos?per_page=100&type=all",
                    "--jq", ".[] | select((.archived | not) and (.fork | not)) | {name, default_branch}"], token)
    if code != 0 or not out.strip():
        raise SystemExit("check-dependabot-drift: the run did not read the list of repos")
    repos = []
    for line in out.splitlines():
        repo = json.loads(line)
        name = repo["name"]
        code, tree = gh(["api", f"repos/{ORG}/{name}/git/trees/{repo['default_branch']}?recursive=1",
                         "--jq", ".tree[] | select(.type == \"blob\") | {path}"], token)
        if code != 0:
            continue  # an empty repo has no tree
        paths = [json.loads(row)["path"] for row in tree.splitlines() if row.strip()]
        text = None
        if ".github/dependabot.yml" in paths:
            code, text = gh(["api", f"repos/{ORG}/{name}/contents/.github/dependabot.yml",
                             "-H", "Accept: application/vnd.github.raw"], token)
            if code != 0:
                text = None
        repos.append((name, paths, text))
    return repos


# --- self-test ---------------------------------------------------------------

def selftest() -> int:
    failures = []

    def expect(name, ok):
        if not ok:
            failures.append(name)

    template = (ROOT / "templates" / "dependabot.yml").read_text()
    paths = ["go.mod", "web/package.json", "Dockerfile", ".github/workflows/ci.yml",
             "node_modules/x/package.json", "internal/testdata/go.mod"]
    expect("the template is clean", check_repo("r", paths, template) == [])
    expect("a manifest under node_modules or testdata does not count",
           ecosystems_of(["node_modules/x/package.json", "a/testdata/go.mod"]) == set())
    cfg = yaml.safe_load(template)

    def mutated(change) -> list:
        import copy
        c = copy.deepcopy(cfg)
        change(c)
        return check_repo("r", paths, yaml.safe_dump(c))

    # Each fixture below must FAIL with the named rule.
    def daily(c): c["updates"][0]["schedule"]["interval"] = "daily"
    def no_group(c): del c["updates"][0]["groups"]
    def major_ignored(c): c["updates"][0]["ignore"] = [{"dependency-name": "*", "update-types": ["version-update:semver-major"]}]
    def all_in_group(c): del c["updates"][3]["groups"]["docker-deps"]["update-types"]
    def one_pin(c): c["updates"][0]["ignore"] = [{"dependency-name": "google.golang.org/grpc", "versions": [">=1.80"]}]
    def no_prefix(c): del c["updates"][1]["commit-message"]
    def no_npm(c): del c["updates"][1]
    expect("a daily schedule fails", ("r", "gomod", "weekly") in mutated(daily))
    expect("an entry with no group fails", ("r", "gomod", "group") in mutated(no_group))
    expect("an ignore of each major update fails", ("r", "gomod", "ignore-major") in mutated(major_ignored))
    expect("a group that holds a major update fails", ("r", "docker", "major-in-group") in mutated(all_in_group))
    expect("an ignore of one dependency is a named difference",
           ("r", "gomod", "ignore:google.golang.org/grpc") in mutated(one_pin))
    expect("an entry with no commit prefix fails", ("r", "npm", "prefix") in mutated(no_prefix))
    expect("a manifest with no entry fails", ("r", "npm", "missing-entry") in mutated(no_npm))
    expect("a repo with a manifest and no file fails",
           check_repo("r", ["go.mod"], None) == [("r", "gomod", "missing-file")])
    expect("a repo with no manifest and no file passes", check_repo("r", ["README.md"], None) == [])
    expect("the codeql-action group can hold a major update",
           not any(rule == "major-in-group" for _, eco, rule in check_repo("r", paths, template)))

    findings = mutated(one_pin)
    ok_exc = [{"repo": "r", "ecosystem": "gomod", "rule": "ignore:google.golang.org/grpc", "reason": "pinned"}]
    left, exempt = apply_exceptions(findings, ok_exc)
    expect("an exception with a reason exempts the finding", left == [] and exempt == 1)
    left, _ = apply_exceptions(findings, [])
    expect("a difference with no exception is left", left == ["r: gomod: ignore:google.golang.org/grpc"])
    left, _ = apply_exceptions([], ok_exc)
    expect("an exception that exempts nothing is a finding", any("exempts no finding" in m for m in left))
    left, _ = apply_exceptions(findings, [dict(ok_exc[0], reason=" ")])
    expect("an exception with no reason is a finding", any("has no reason" in m for m in left))

    if failures:
        for f in failures:
            print(f"check-dependabot-drift: selftest FAILED: {f}", file=sys.stderr)
        return 1
    print("check-dependabot-drift: selftest OK (16 cases, 11 must fail)")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print(__doc__, file=sys.stderr)
        return 2
    token = os.environ.get("READ_TOKEN") or os.environ.get("GH_TOKEN", "")
    if not token:
        print("check-dependabot-drift: set READ_TOKEN or GH_TOKEN", file=sys.stderr)
        return 2
    exceptions = json.loads(EXCEPTIONS.read_text()).get("exceptions", [])
    repos = read_org(token)
    if len(repos) < 5:
        print(f"check-dependabot-drift: the run read {len(repos)} repos, and the floor is 5", file=sys.stderr)
        return 2
    findings = []
    for name, paths, text in repos:
        findings += check_repo(name, paths, text)
    left, exempt = apply_exceptions(findings, exceptions)
    for message in left:
        print(f"check-dependabot-drift: {message}", file=sys.stderr)
    if left:
        print(f"check-dependabot-drift: {len(left)} finding(s) in {len(repos)} repos. "
              "The form is templates/dependabot.yml.", file=sys.stderr)
        return 1
    print(f"check-dependabot-drift: OK. {len(repos)} repos agree with the template, with {exempt} named difference(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
