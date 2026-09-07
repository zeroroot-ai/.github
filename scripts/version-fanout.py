#!/usr/bin/env python3
"""version-fanout.py — a source published a version; open ONE PR per consumer.

Epic zeroroot-ai/.github#20, slice #24. `version-links.yaml` names each link:
the source a human edits, and the consumers that must equal it. This script
reads the source value, rewrites every consumer key, and opens or updates one
PR per consumer repo. The org's sdk fan-out is the model; this is the same
shape for any link in the manifest.

Rules (proved by --selftest, which gates this repo's PRs):
  * One PR per consumer repo per value, on the branch
    chore/version-fanout-<link>-<value>. A rerun for the same value pushes the
    branch again and edits the PR in place. Older fan-out PRs for the same
    link are closed as superseded.
  * A consumer key is rewritten by line: quotes, indentation and trailing
    comments survive, and no other line changes (several chart guards are
    line-anchored). An image pin (`before: "@"` with an `image:` name) gets
    the digest of `ghcr.io/zeroroot-ai/<image>:<value>` resolved from the
    registry, and is written through the consumer's own
    scripts/bump-image-digest.py when it has one.
  * A missing link, key, or digest is an error. Nothing is pushed for a
    consumer that errored; the run goes red.
  * Auto-merge is never armed. The PR goes through the consumer's own merge
    gate and sign-off (ADR-0012).

Usage:
  version-fanout.py --link zitadel [--manifest version-links.yaml] [--value v4.17.3]
                    [--source-ref main] [--dry-run] [--work DIR]
  version-fanout.py --selftest
Env: GH_TOKEN (pushes and PRs on the consumers), GHCR_TOKEN (registry reads;
     defaults to GH_TOKEN).
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

REGISTRY = "ghcr.io/zeroroot-ai"
BOT_NAME = "zeroday-sdk-fanout[bot]"
BOT_MAIL = "zeroday-sdk-fanout[bot]@users.noreply.github.com"
EPIC = "zeroroot-ai/.github#20"


class FanoutError(Exception):
    pass


def sh(*args: str, cwd: str | None = None, env: dict | None = None, check: bool = True) -> str:
    r = subprocess.run(list(args), cwd=cwd, env=env, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise FanoutError(f"{' '.join(args[:3])}: {r.stderr.strip()[:400]}")
    return r.stdout


def yaml_to_json(text: str) -> dict:
    r = subprocess.run(["yq", "-o=json", "-I=0", "."], input=text, capture_output=True, text=True)
    if r.returncode != 0:
        raise FanoutError(f"yq: {r.stderr.strip()[:200]}")
    return json.loads(r.stdout or "{}")


# --------------------------------------------------------------------------
# Line rewriters. They change exactly one line and keep everything else.
def set_env_key(text: str, key: str, value: str) -> str:
    out, hit = [], False
    for line in text.splitlines(keepends=True):
        s = line.strip()
        if not s.startswith("#") and "=" in s and s.split("=", 1)[0].strip() == key:
            out.append(f"{key}={value}\n")
            hit = True
        else:
            out.append(line)
    if not hit:
        raise FanoutError(f"env key {key} not found")
    return "".join(out)


def set_yaml_scalar(text: str, dotted: str, value: str) -> str:
    """Rewrite the scalar at a dotted key path, tracking the path by indentation."""
    target = dotted.split(".")
    stack: list[tuple[int, str]] = []
    out, hit = [], False
    for line in text.splitlines(keepends=True):
        m = re.match(r"^(\s*)([A-Za-z0-9_.\-/]+):(.*)$", line.rstrip("\n"))
        if line.strip() == "" or line.lstrip().startswith("#") or line.lstrip().startswith("- ") or not m:
            out.append(line)
            continue
        indent, key, rest = len(m.group(1)), m.group(2), m.group(3)
        while stack and stack[-1][0] >= indent:
            stack.pop()
        stack.append((indent, key))
        if [k for _, k in stack] == target and not hit:
            vm = re.match(r'^(\s*)("([^"]*)"|\'([^\']*)\'|([^#\s]+))?(\s*(#.*)?)$', rest)
            if not vm or vm.group(2) is None:
                raise FanoutError(f"yaml key {dotted} has no scalar on its line")
            quote = '"' if vm.group(3) is not None else ("'" if vm.group(4) is not None else "")
            newrest = f"{vm.group(1)}{quote}{value}{quote}{vm.group(6) or ''}"
            out.append(f"{m.group(1)}{key}:{newrest}\n")
            hit = True
        else:
            out.append(line)
    if not hit:
        raise FanoutError(f"yaml key {dotted} not found")
    return "".join(out)


# --------------------------------------------------------------------------
# GitHub / registry boundary. The selftest swaps this class.
class Gateway:
    def __init__(self, token: str, ghcr_token: str):
        self.token, self.ghcr_token = token, ghcr_token
        self.env = dict(os.environ, GH_TOKEN=token, GIT_TERMINAL_PROMPT="0")

    def file_text(self, repo: str, path: str, ref: str) -> str:
        out = sh("gh", "api", f"repos/{repo}/contents/{path}?ref={ref}", "--jq", ".content", env=self.env)
        return base64.b64decode(out).decode()

    def resolve_digest(self, image: str, ref: str) -> str:
        repo = f"zeroroot-ai/{image}"
        basic = base64.b64encode(f"x:{self.ghcr_token}".encode()).decode()
        req = urllib.request.Request(f"https://ghcr.io/token?service=ghcr.io&scope=repository:{repo}:pull",
                                     headers={"Authorization": f"Basic {basic}"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                bearer = json.load(r).get("token")
            req = urllib.request.Request(f"https://ghcr.io/v2/{repo}/manifests/{ref}", method="HEAD", headers={
                "Authorization": f"Bearer {bearer}",
                "Accept": ", ".join([
                    "application/vnd.oci.image.index.v1+json",
                    "application/vnd.docker.distribution.manifest.list.v2+json",
                    "application/vnd.oci.image.manifest.v1+json",
                    "application/vnd.docker.distribution.manifest.v2+json"])})
            with urllib.request.urlopen(req, timeout=30) as r:
                digest = r.headers.get("Docker-Content-Digest", "")
        except urllib.error.URLError as e:
            raise FanoutError(f"registry: {REGISTRY}/{image}:{ref}: {e}") from e
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest or ""):
            raise FanoutError(f"registry: no digest for {REGISTRY}/{image}:{ref}")
        return digest

    def clone(self, repo: str, dest: str) -> None:
        sh("git", "clone", "--quiet", "--depth", "50", f"https://x-access-token:{self.token}@github.com/{repo}.git", dest, env=self.env)
        sh("git", "config", "user.name", BOT_NAME, cwd=dest)
        sh("git", "config", "user.email", BOT_MAIL, cwd=dest)

    def push_branch(self, dest: str, branch: str) -> None:
        sh("git", "push", "--force-with-lease", "--quiet", "-u", "origin", branch, cwd=dest, env=self.env)

    def open_pr_for_branch(self, repo: str, branch: str) -> int | None:
        out = sh("gh", "pr", "list", "-R", repo, "--head", branch, "--state", "open", "--json", "number", env=self.env)
        items = json.loads(out or "[]")
        return int(items[0]["number"]) if items else None

    def create_pr(self, repo: str, branch: str, title: str, body: str) -> str:
        return sh("gh", "pr", "create", "-R", repo, "--head", branch, "--base", "main", "--title", title, "--body", body, env=self.env).strip()

    def edit_pr(self, repo: str, number: int, title: str, body: str) -> None:
        sh("gh", "pr", "edit", str(number), "-R", repo, "--title", title, "--body", body, env=self.env)

    def superseded_prs(self, repo: str, prefix: str, keep_branch: str) -> list[int]:
        out = sh("gh", "pr", "list", "-R", repo, "--state", "open", "--json", "number,headRefName", env=self.env)
        return [int(p["number"]) for p in json.loads(out or "[]")
                if p["headRefName"].startswith(prefix) and p["headRefName"] != keep_branch]

    def close_pr(self, repo: str, number: int, comment: str) -> None:
        sh("gh", "pr", "close", str(number), "-R", repo, "--delete-branch", "--comment", comment, env=self.env)


# --------------------------------------------------------------------------
def find_link(manifest: dict, name: str) -> dict:
    for link in manifest.get("links", []):
        if link.get("name") == name:
            return link
    raise FanoutError(f"link {name} not in manifest")


def read_key(text: str, fmt: str, key: str) -> str:
    if fmt == "env":
        for line in text.splitlines():
            s = line.strip()
            if not s.startswith("#") and "=" in s and s.split("=", 1)[0].strip() == key:
                return s.split("=", 1)[1].strip().strip('"').strip("'")
        raise FanoutError(f"env key {key} not found")
    node = yaml_to_json(text)
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            raise FanoutError(f"yaml key {key} not found")
        node = node[part]
    return str(node)


def pr_body(link: str, value: str, source: dict, changes: list[str]) -> str:
    lines = [f"## What", "",
             f"Bump the `{link}` link to `{value}`. Source: `{source['repo']}:{source['file']}:{source['key']}`.", "",
             "Changed keys:"] + [f"- `{c}`" for c in changes] + [
             "", "## Why", "",
             f"The source moved. `version-links.yaml` names this consumer, and the fan-out keeps it equal ({EPIC}). "
             "This PR goes through the normal merge gate and sign-off. Nothing arms auto-merge.", "",
             "Docs-PR: not-applicable: automated version fan-out", "",
             "_Auto-generated by zeroroot-ai/.github reusable-version-fanout. A rerun for the same value updates this PR in place._"]
    return "\n".join(lines)


def apply_consumer(dest: str, c: dict, value: str, gw) -> str:
    """Rewrite one consumer key in a checked-out repo. Returns the change label."""
    path = os.path.join(dest, c["file"])
    if not os.path.isfile(path):
        raise FanoutError(f"{c['repo']}:{c['file']} missing")
    text = open(path).read()
    if c.get("after"):
        raise FanoutError(f"{c['repo']}:{c['file']}:{c['key']} is an `after` consumer (inline image reference); "
                          "the fan-out does not rewrite those, edit it by hand")
    if c["format"] == "env":
        open(path, "w").write(set_env_key(text, c["key"], value))
        return f"{c['file']}:{c['key']} = {value}"
    if c.get("image"):
        digest = gw.resolve_digest(c["image"], value)
        helper = os.path.join(dest, "scripts", "bump-image-digest.py")
        if os.path.isfile(helper):
            sh(sys.executable, helper, "--image", c["image"], "--ref", value, "--digest", digest, cwd=dest)
            after = read_key(open(path).read(), "yaml", c["key"])
            if not after.startswith(f"{value}@"):
                raise FanoutError(f"{c['repo']}: bump-image-digest.py did not rewrite {c['key']} (now {after})")
        else:
            open(path, "w").write(set_yaml_scalar(text, c["key"], f"{value}@{digest}"))
        return f"{c['file']}:{c['key']} = {value}@{digest[:19]}…"
    open(path, "w").write(set_yaml_scalar(text, c["key"], value))
    return f"{c['file']}:{c['key']} = {value}"


def fanout(manifest: dict, link_name: str, gw, value: str | None, source_ref: str,
           dry_run: bool, work: str) -> int:
    link = find_link(manifest, link_name)
    src = link["source"]
    if not value:
        value = read_key(gw.file_text(src["repo"], src["file"], source_ref), src["format"], src["key"])
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", value):
        raise FanoutError(f"refusing to fan out an unsafe value {value!r}")
    branch = f"chore/version-fanout-{link_name}-{value}"
    by_repo: dict[str, list[dict]] = {}
    for c in link.get("consumers", []):
        by_repo.setdefault(c["repo"], []).append(c)
    print(f"link {link_name}: source {src['repo']} = {value}; consumers in {len(by_repo)} repo(s)")
    failures = 0
    for repo, consumers in by_repo.items():
        dest = os.path.join(work, repo.replace("/", "__"))
        shutil.rmtree(dest, ignore_errors=True)
        try:
            gw.clone(repo, dest)
            sh("git", "checkout", "-q", "-B", branch, cwd=dest)
            changes = [apply_consumer(dest, c, value, gw) for c in consumers]
            if not sh("git", "status", "--porcelain", cwd=dest).strip():
                print(f"{repo}: already at {value}; nothing to open")
                continue
            for c in consumers:
                sh("git", "add", "--", c["file"], cwd=dest)
            title = f"fix({link_name}): bump to {value}"
            body = pr_body(link_name, value, src, changes)
            sh("git", "commit", "-q", "-m", title, "-m", f"Automated by zeroroot-ai/.github reusable-version-fanout ({EPIC}).",
               "-m", f"Co-Authored-By: {BOT_NAME} <{BOT_MAIL}>", cwd=dest)
            print(f"{repo}: {len(changes)} change(s): " + "; ".join(changes))
            if dry_run:
                print(sh("git", "show", "--stat", "--format=", "HEAD", cwd=dest))
                continue
            gw.push_branch(dest, branch)
            existing = gw.open_pr_for_branch(repo, branch)
            if existing:
                gw.edit_pr(repo, existing, title, body)
                print(f"::notice::{repo}: updated PR #{existing} in place")
            else:
                print(f"::notice::{repo}: opened {gw.create_pr(repo, branch, title, body)}")
            for old in gw.superseded_prs(repo, f"chore/version-fanout-{link_name}-", branch):
                gw.close_pr(repo, old, f"Superseded by the fan-out to {value} (one open fan-out PR per link).")
                print(f"{repo}: closed superseded PR #{old}")
        except FanoutError as e:
            failures += 1
            print(f"::error::{repo}: {e}", file=sys.stderr)
    return 1 if failures else 0


# --------------------------------------------------------------------------
class FixtureGateway:
    def __init__(self, files: dict, digests: dict, open_prs: dict | None = None, fail_digest: bool = False):
        self.files, self.digests, self.open_prs = files, digests, open_prs or {}
        self.fail_digest = fail_digest
        self.calls: list[tuple] = []

    def file_text(self, repo, path, ref):
        try:
            return self.files[(repo, path)]
        except KeyError:
            raise FanoutError("HTTP 404 mocked") from None

    def resolve_digest(self, image, ref):
        if self.fail_digest:
            raise FanoutError("registry: mocked failure")
        return self.digests[(image, ref)]

    def clone(self, repo, dest):
        os.makedirs(dest, exist_ok=True)
        sh("git", "init", "-q", dest)
        sh("git", "config", "user.name", "t", cwd=dest); sh("git", "config", "user.email", "t@t", cwd=dest)
        for (r, path), text in self.files.items():
            if r == repo:
                full = os.path.join(dest, path); os.makedirs(os.path.dirname(full), exist_ok=True)
                open(full, "w").write(text)
        sh("git", "add", "-A", cwd=dest); sh("git", "commit", "-q", "-m", "base", cwd=dest)

    def push_branch(self, dest, branch):
        self.calls.append(("push", branch))

    def open_pr_for_branch(self, repo, branch):
        return self.open_prs.get((repo, branch))

    def create_pr(self, repo, branch, title, body):
        self.calls.append(("create", repo, branch, title, body)); return "https://github.com/mock/pull/1"

    def edit_pr(self, repo, number, title, body):
        self.calls.append(("edit", repo, number, title, body))

    def superseded_prs(self, repo, prefix, keep_branch):
        return [n for (r, b), n in self.open_prs.items() if r == repo and b.startswith(prefix) and b != keep_branch]

    def close_pr(self, repo, number, comment):
        self.calls.append(("close", repo, number, comment))


VALUES = ('zitadel:\n  # server\n  image:\n    tag: "v4.14.0"  # pinned, see note\n  login:\n    image:\n'
          '      repository: "ghcr.io/zeroroot-ai/zitadel-login"\n      tag: "sha-f41ce75@sha256:' + "a" * 64 + '"\n'
          'other:\n  image:\n    tag: "v9.9.9"\n')
MANIFEST = {"version": 1, "links": [{
    "name": "zitadel",
    "source": {"repo": "o/fork", "file": "UPSTREAM_REF", "key": "TAG", "format": "env"},
    "consumers": [
        {"repo": "o/charts", "file": "helm/values.yaml", "key": "zitadel.image.tag", "format": "yaml"},
        {"repo": "o/charts", "file": "helm/values.yaml", "key": "zitadel.login.image.tag", "format": "yaml", "before": "@", "image": "zitadel-login"},
        {"repo": "o/other", "file": "cfg.env", "key": "ZITADEL_TAG", "format": "env"},
    ]}]}
DIG = "sha256:" + "b" * 64


def selftest() -> int:
    passed = failed = 0

    def check(cond, name):
        nonlocal passed, failed
        print(("PASS: " if cond else "FAIL: ") + name); passed += bool(cond); failed += (not cond)

    # rewriters
    t = set_yaml_scalar(VALUES, "zitadel.image.tag", "v4.17.3")
    check('    tag: "v4.17.3"  # pinned, see note' in t, "yaml rewrite keeps quotes, indent and the trailing comment")
    check(t.count("v9.9.9") == 1 and "sha-f41ce75" in t, "yaml rewrite touches no other tag line")
    check(sum(1 for a, b in zip(VALUES.splitlines(), t.splitlines()) if a != b) == 1, "yaml rewrite changes exactly one line")
    try:
        set_yaml_scalar(VALUES, "zitadel.nope.tag", "x"); check(False, "missing yaml key raises")
    except FanoutError:
        check(True, "missing yaml key raises")
    e = set_env_key("# c\nREPO=x\nTAG=v4.14.0\nCOMMIT=1\n", "TAG", "v4.17.3")
    check(e == "# c\nREPO=x\nTAG=v4.17.3\nCOMMIT=1\n", "env rewrite changes exactly the key line")
    check(read_key("A=1\nTAG='v1'\n", "env", "TAG") == "v1", "env read strips quotes")

    files = {("o/fork", "UPSTREAM_REF"): "TAG=v4.17.3\n", ("o/charts", "helm/values.yaml"): VALUES, ("o/other", "cfg.env"): "ZITADEL_TAG=v4.14.0\n"}
    # 1. full fan-out: one PR per consumer repo, both charts keys in one commit, digest resolved
    with tempfile.TemporaryDirectory() as w:
        gw = FixtureGateway(files, {("zitadel-login", "v4.17.3"): DIG})
        rc = fanout(MANIFEST, "zitadel", gw, None, "main", False, w)
        creates = [c for c in gw.calls if c[0] == "create"]
        check(rc == 0 and len(creates) == 2, "one PR per consumer repo (charts, other)")
        check(all(c[2] == "chore/version-fanout-zitadel-v4.17.3" for c in creates), "branch names carry link and value")
        charts_body = [c[4] for c in creates if c[1] == "o/charts"][0]
        check("zitadel.image.tag = v4.17.3" in charts_body and "zitadel.login.image.tag = v4.17.3@sha256:bbbbbbbbbbbb" in charts_body,
              "charts PR body names both keys, the pin with its digest")
        check("auto-merge" in charts_body.lower() and "Docs-PR:" in charts_body, "PR body says no auto-merge and carries the Docs-PR trailer")
        values_after = open(os.path.join(w, "o__charts", "helm/values.yaml")).read()
        check(f'tag: "v4.17.3@{DIG}"' in values_after and 'tag: "v4.17.3"  # pinned' in values_after, "both chart lines rewritten on disk")
    # 2. explicit --value overrides the source read
    with tempfile.TemporaryDirectory() as w:
        gw = FixtureGateway(files, {("zitadel-login", "v4.18.0"): DIG})
        fanout(MANIFEST, "zitadel", gw, "v4.18.0", "main", False, w)
        check(any(c[0] == "create" and "v4.18.0" in c[3] for c in gw.calls), "--value overrides the source")
    # 3. rerun with an open PR on the same branch -> edit in place, no create; older fan-out PR closed
    with tempfile.TemporaryDirectory() as w:
        gw = FixtureGateway(files, {("zitadel-login", "v4.17.3"): DIG},
                            open_prs={("o/charts", "chore/version-fanout-zitadel-v4.17.3"): 41, ("o/charts", "chore/version-fanout-zitadel-v4.16.0"): 40})
        fanout(MANIFEST, "zitadel", gw, None, "main", False, w)
        kinds = [(c[0], c[1]) for c in gw.calls if c[0] in ("create", "edit", "close")]
        check(("edit", "o/charts") in kinds and ("create", "o/charts") not in kinds, "existing PR is edited in place")
        check(("close", "o/charts") in kinds and [c for c in gw.calls if c[0] == "close"][0][2] == 40, "the older fan-out PR is closed as superseded")
    # 4. consumer already at the value -> nothing pushed
    with tempfile.TemporaryDirectory() as w:
        same = dict(files); same[("o/other", "cfg.env")] = "ZITADEL_TAG=v4.17.3\n"
        gw = FixtureGateway(same, {("zitadel-login", "v4.17.3"): DIG})
        fanout(MANIFEST, "zitadel", gw, None, "main", False, w)
        check(not any(c[0] == "create" and c[1] == "o/other" for c in gw.calls), "a consumer already at the value gets no PR")
    # 5. digest resolution failure -> that consumer errors, run red, nothing pushed for it
    with tempfile.TemporaryDirectory() as w:
        gw = FixtureGateway(files, {}, fail_digest=True)
        rc = fanout(MANIFEST, "zitadel", gw, None, "main", False, w)
        check(rc == 1 and not any(c[0] == "create" and c[1] == "o/charts" for c in gw.calls),
              "registry failure is loud and opens nothing for that consumer")
        check(any(c[0] == "create" and c[1] == "o/other" for c in gw.calls), "the unaffected consumer still gets its PR")
    # 6. dry-run pushes and opens nothing
    with tempfile.TemporaryDirectory() as w:
        gw = FixtureGateway(files, {("zitadel-login", "v4.17.3"): DIG})
        rc = fanout(MANIFEST, "zitadel", gw, None, "main", True, w)
        check(rc == 0 and not gw.calls, "dry-run makes no push or PR call")
    # 7. unknown link / unsafe value are errors
    try:
        fanout(MANIFEST, "nope", FixtureGateway(files, {}), None, "main", True, tempfile.mkdtemp()); check(False, "unknown link raises")
    except FanoutError:
        check(True, "unknown link raises")
    try:
        fanout(MANIFEST, "zitadel", FixtureGateway(files, {}), "v1; rm -rf /", "main", True, tempfile.mkdtemp()); check(False, "unsafe value refused")
    except FanoutError:
        check(True, "unsafe value refused")
    # 8. the real manifest names an image for every `before: "@"` consumer
    real = yaml_to_json(open(os.path.join(os.path.dirname(__file__), "..", "version-links.yaml")).read())
    check(all(c.get("image") for l in real["links"] for c in l.get("consumers", []) if c.get("before")),
          "every image-pin consumer in version-links.yaml names its image")
    # an `after` consumer (inline image reference) is drift-only: the fan-out refuses it loudly
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "values.yaml"), "w").write("zitadel:\n  initContainers:\n    - image: ghcr.io/o/alpine-k8s:1.31.0\n")
        try:
            apply_consumer(d, {"repo": "o/charts", "file": "values.yaml", "key": "zitadel.initContainers.0.image",
                               "format": "yaml", "after": ":"}, "1.33.0", None)
            check(False, "`after` consumer is refused")
        except FanoutError as e:
            check("after" in str(e), "`after` consumer is refused with a message that names it")

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--link"); ap.add_argument("--manifest", default="version-links.yaml")
    ap.add_argument("--value"); ap.add_argument("--source-ref", default="main")
    ap.add_argument("--dry-run", action="store_true"); ap.add_argument("--work", default=None)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.link:
        ap.error("--link is required")
    token = os.environ.get("GH_TOKEN") or sh("gh", "auth", "token").strip()
    gw = Gateway(token, os.environ.get("GHCR_TOKEN") or token)
    manifest = yaml_to_json(open(a.manifest).read())
    work = a.work or tempfile.mkdtemp(prefix="version-fanout-")
    try:
        return fanout(manifest, a.link, gw, a.value, a.source_ref, a.dry_run, work)
    except FanoutError as e:
        print(f"::error::{e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
