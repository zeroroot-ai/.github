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
    gate (ADR-0080).
  * A consumer may name `sources`: repos the fan-out clones at the released
    tag beside the consumer clone, so a `regenerate` command can read them as
    sibling checkouts (.github#275: the charts env reader contract). The
    clones keep no token.
  * A consumer may name `verify` commands. They run after `regenerate`, with
    no token. A failing one pushes nothing: the fan-out does not open a PR
    that the consumer's gate would refuse.
  * The fan-out installs the Helm that a consumer requires, read from the
    consumer clone itself: the `GOLDEN_HELM_VERSION="vX.Y.Z"` line of its
    scripts/golden.sh, which that script checks with require-helm.sh
    (charts#789). It verifies the download against the published SHA-256
    and puts that Helm first on PATH for `regenerate` and `verify`. The
    reusable workflow pins no Helm of its own: a second copy drifted
    (Helm v3.16.2 against v4.2.1) and failed every charts fan-out.
  * `--refresh` rebuilds each open fan-out PR that fell behind the consumer's
    main: the same value, rewritten on current main and regenerated again.
    The digest comes from the open PR, so no registry read is needed.

Usage:
  version-fanout.py --link zitadel [--manifest version-links.yaml] [--value v4.17.3]
                    [--source-ref main] [--dry-run] [--work DIR]
  version-fanout.py --refresh [--manifest version-links.yaml] [--dry-run]
  version-fanout.py --selftest
Env: GH_TOKEN (pushes and PRs on the consumers), GHCR_TOKEN (registry reads;
     defaults to GH_TOKEN).
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request

REGISTRY = "ghcr.io/zeroroot-ai"
BOT_NAME = "zeroday-sdk-fanout[bot]"
BOT_MAIL = "zeroday-sdk-fanout[bot]@users.noreply.github.com"
EPIC = "zeroroot-ai/.github#20"
# The login `gh` reports for a PR the fan-out App opened. --refresh rebuilds
# only those: a PR from another author or a fork is not the fan-out's to push.
APP_AUTHOR = "app/zeroday-sdk-fanout"


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


def split_key(dotted: str) -> list[str]:
    """Split a yaml key path on dots. `\\.` is a literal dot inside one key,
    for a map whose keys are dotted themselves (Neo4j settings such as
    `dbms.security.procedures.allowlist`, gibson#28). Mirrors version-drift.py."""
    return [p.replace("\\.", ".") for p in re.split(r"(?<!\\)\.", dotted)]


def set_yaml_scalar(text: str, dotted: str, value: str) -> str:
    """Rewrite the scalar at a dotted key path, tracking the path by indentation."""
    target = split_key(dotted)
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


def push_with_lease(dest: str, branch: str, env: dict | None = None) -> None:
    """Force-push the fan-out branch with a lease that names what the remote holds.

    The clone is shallow and the branch is created locally, so there is no
    remote-tracking ref for it. A bare `--force-with-lease` then has no lease
    to check and rejects a rerun ("stale info"): the second live fan-out
    (zitadel-login run after .github#37) failed exactly there. Fetch the
    remote branch first; the lease is its tip, or "must not exist" when the
    branch is new. A rerun updates the bot's own branch and nothing else.
    """
    r = subprocess.run(["git", "fetch", "-q", "origin", f"refs/heads/{branch}"], cwd=dest, env=env, capture_output=True, text=True)
    expect = sh("git", "rev-parse", "FETCH_HEAD", cwd=dest, env=env).strip() if r.returncode == 0 else ""
    sh("git", "push", f"--force-with-lease=refs/heads/{branch}:{expect}", "--quiet", "-u", "origin", branch, cwd=dest, env=env)


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

    def helm_release(self, version: str) -> tuple[bytes, str]:
        """The linux-amd64 tarball of a Helm release and its published SHA-256."""
        base = f"https://get.helm.sh/helm-{version}-linux-amd64.tar.gz"
        with urllib.request.urlopen(base, timeout=120) as r:
            tarball = r.read()
        with urllib.request.urlopen(base + ".sha256sum", timeout=60) as r:
            published = r.read().decode().split()[0]
        return tarball, published

    def helm_login(self, helm: str) -> None:
        """Log the installed Helm in to ghcr.io for the mirrored sub-charts."""
        user = os.environ.get("GITHUB_ACTOR") or "x-access-token"
        r = subprocess.run([helm, "registry", "login", "ghcr.io", "-u", user, "--password-stdin"],
                           input=self.ghcr_token, capture_output=True, text=True)
        if r.returncode != 0:
            raise FanoutError(f"helm registry login ghcr.io failed: {(r.stderr or r.stdout).strip()[-400:]}")

    def clone(self, repo: str, dest: str) -> None:
        sh("git", "clone", "--quiet", "--depth", "50", f"https://x-access-token:{self.token}@github.com/{repo}.git", dest, env=self.env)
        sh("git", "config", "user.name", BOT_NAME, cwd=dest)
        sh("git", "config", "user.email", BOT_MAIL, cwd=dest)

    def push_branch(self, dest: str, branch: str) -> None:
        push_with_lease(dest, branch, self.env)

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

    def clone_source(self, repo: str, tag: str, dest: str) -> None:
        """Clone `repo` at `tag` (or `<name>-<tag>`) with the tag ref, then drop the token from its remote."""
        name = repo.split("/", 1)[1]
        for ref in (tag, f"{name}-{tag}"):
            r = subprocess.run(["git", "clone", "--quiet", "--depth", "1", "--branch", ref,
                                f"https://x-access-token:{self.token}@github.com/{repo}.git", dest],
                               env=self.env, capture_output=True, text=True)
            if r.returncode == 0:
                sh("git", "remote", "set-url", "origin", f"https://github.com/{repo}.git", cwd=dest)
                return
            shutil.rmtree(dest, ignore_errors=True)
        raise FanoutError(f"source {repo} has no tag {tag} or {name}-{tag}")

    def open_fanout_prs(self, repo: str, prefix: str) -> list[tuple[int, str]]:
        """Open PRs on a fan-out branch that the fan-out App opened in the repo itself."""
        out = sh("gh", "pr", "list", "-R", repo, "--state", "open", "--json",
                 "number,headRefName,author,isCrossRepository", env=self.env)
        return [(int(p["number"]), p["headRefName"]) for p in json.loads(out or "[]")
                if fanout_owned(p, prefix)]

    def behind_main(self, repo: str, branch: str) -> int:
        r = subprocess.run(["gh", "api", f"repos/{repo}/compare/main...{branch}", "--jq", ".behind_by"],
                           env=self.env, capture_output=True, text=True)
        if r.returncode != 0:
            raise FanoutError(f"compare main...{branch}: {(r.stderr or r.stdout).strip()[-300:]}")
        return int(r.stdout.strip() or 0)


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
    for part in split_key(key):
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
             "This PR goes through the normal merge gate. Nothing arms auto-merge.", "",
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


# The fan-out's own credentials. A consumer's `regenerate` command is that
# consumer's code (`./scripts/golden.sh`, `./airgap/generate-image-list.py`),
# so write access to one consumer must not turn into the App token that can
# push branches and open PRs on every consumer in the link.
FANOUT_TOKENS = ("GH_TOKEN", "GITHUB_TOKEN", "GHCR_TOKEN", "GH_ENTERPRISE_TOKEN")


def regenerate_env() -> dict[str, str]:
    """The environment a consumer's `regenerate` command runs in: ours, minus every token."""
    return {k: v for k, v in os.environ.items() if k not in FANOUT_TOKENS}


# The Helm a consumer requires lives in the consumer, never in this repo. The
# golden step of charts checks it (scripts/golden.sh calls require-helm.sh with
# GOLDEN_HELM_VERSION), so the fan-out reads that one line from the clone.
HELM_VERSION_FILE = "scripts/golden.sh"
HELM_VERSION_RE = re.compile(r'^GOLDEN_HELM_VERSION="(v\d+\.\d+\.\d+)"$', re.M)
_HELM_DIRS: dict[str, str] = {}


def consumer_helm_version(dest: str) -> str | None:
    """The Helm version the consumer clone requires, or None when it names none."""
    path = os.path.join(dest, HELM_VERSION_FILE)
    if not os.path.isfile(path):
        return None
    found = HELM_VERSION_RE.findall(open(path).read())
    if len(found) > 1:
        raise FanoutError(f"{HELM_VERSION_FILE} names {len(found)} Helm versions; it must name one")
    return found[0] if found else None


def install_helm(version: str, gw) -> str:
    """Install one Helm release, verified against its published SHA-256. Returns its directory."""
    if version in _HELM_DIRS:
        return _HELM_DIRS[version]
    tarball, published = gw.helm_release(version)
    got = hashlib.sha256(tarball).hexdigest()
    if not re.fullmatch(r"[0-9a-f]{64}", published or "") or got != published:
        raise FanoutError(f"Helm {version}: the download has SHA-256 {got}, the published sum is {published!r}")
    d = tempfile.mkdtemp(prefix=f"helm-{version}-")
    with tarfile.open(fileobj=io.BytesIO(tarball), mode="r:gz") as t:
        member = t.getmember("linux-amd64/helm")
        f = t.extractfile(member)
        if f is None:
            raise FanoutError(f"Helm {version}: the tarball has no linux-amd64/helm file")
        helm = os.path.join(d, "helm")
        open(helm, "wb").write(f.read())
    os.chmod(helm, 0o755)
    gw.helm_login(helm)
    _HELM_DIRS[version] = d
    print(f"helm {version}: installed and verified (sha256 {got[:12]}…)")
    return d


def consumer_env(dest: str, gw) -> dict[str, str]:
    """The environment of a consumer command, with the consumer's Helm first on PATH.

    It holds no fan-out token. Known limit: install_helm logs Helm in to
    ghcr.io, and that login lives in the Helm registry config under $HOME,
    which a consumer command can read. golden.sh pulls the mirrored sub-charts
    with it, so the consumer needs it. The workflow login step did the same.
    """
    env = regenerate_env()
    version = consumer_helm_version(dest)
    if version:
        env["PATH"] = install_helm(version, gw) + os.pathsep + env.get("PATH", "")
    return env


def regenerate(dest: str, repo: str, consumers: list[dict], gw) -> list[str]:
    """Run the consumer repo's declared `regenerate` commands after the rewrite.

    A consumer may carry derived files (golden snapshots, an air-gap image
    list) that its merge gate compares against the values. charts#26 (the
    first live fan-out) was red on exactly that. The commands come from the
    manifest, run in the clone in declaration order, once per repo, and every
    tracked file they touch joins the commit. Untracked output is a defect in
    the declaration and fails loudly: the fan-out never guesses what to add.
    """
    cmds: list[str] = []
    for c in consumers:
        for cmd in c.get("regenerate", []) or []:
            if cmd not in cmds:
                cmds.append(cmd)
    if not cmds:
        return []
    env = consumer_env(dest, gw)
    for cmd in cmds:
        print(f"{repo}: regenerate: {cmd}")
        r = subprocess.run(["sh", "-c", cmd], cwd=dest, env=env, capture_output=True, text=True)
        if r.returncode != 0:
            raise FanoutError(f"regenerate `{cmd}` failed ({r.returncode}): {(r.stderr or r.stdout).strip()[-800:]}")
    untracked = [ln[3:] for ln in sh("git", "status", "--porcelain", cwd=dest).splitlines() if ln.startswith("??")]
    if untracked:
        raise FanoutError(f"regenerate left untracked files the fan-out will not guess at: {', '.join(untracked)}")
    sh("git", "add", "-u", cwd=dest)
    touched = [ln.strip() for ln in sh("git", "diff", "--cached", "--name-only", cwd=dest).splitlines()]
    consumer_files = {c["file"] for c in consumers}
    return [f"{f} (regenerated)" for f in touched if f not in consumer_files]


def clone_sources(work: str, consumers: list[dict], value: str, gw) -> None:
    """Clone each `sources` repo at the released tag, beside the consumer clone.

    A consumer's generator reads a service at the tag the consumer pins, from a
    sibling checkout (charts scripts/pinned_source.py). The runner has none, so
    the fan-out provides it. The directory is the repo name, which is where a
    sibling lookup finds it; the clone keeps no token.
    """
    for repo in dict.fromkeys(r for c in consumers for r in c.get("sources", []) or []):
        dest = os.path.join(work, repo.split("/", 1)[1])
        shutil.rmtree(dest, ignore_errors=True)
        gw.clone_source(repo, value, dest)


def verify(dest: str, repo: str, consumers: list[dict], gw) -> None:
    """Run the consumer's `verify` commands after `regenerate`, with no token. A failure pushes nothing."""
    cmds = list(dict.fromkeys(cmd for c in consumers for cmd in c.get("verify", []) or []))
    if not cmds:
        return
    env = consumer_env(dest, gw)
    for cmd in cmds:
        print(f"{repo}: verify: {cmd}")
        r = subprocess.run(["sh", "-c", cmd], cwd=dest, env=env, capture_output=True, text=True)
        if r.returncode != 0:
            raise FanoutError(f"verify `{cmd}` failed ({r.returncode}), so the consumer gate would refuse the PR: "
                              f"{(r.stdout + r.stderr).strip()[-800:]}")


def manifest_problems(manifest: dict) -> list[str]:
    """Rules on the manifest itself.

    A chart image pin moves the tag that a vendored contract must name
    (charts `contract-pins`). So every image-pin consumer in charts runs that
    check as `verify`, and a consumer whose service has a contract clones the
    service through `sources` and regenerates the contract (.github#275).
    """
    out = []
    for link in manifest.get("links", []):
        for c in link.get("consumers", []) or []:
            if c.get("repo") == "zeroroot-ai/charts" and c.get("image"):
                if not any("pinned_source.py --check-headers" in v for v in c.get("verify", []) or []):
                    out.append(f"{link['name']}: the charts image pin `{c['key']}` declares no verify that runs "
                               "scripts/pinned_source.py --check-headers")
            for r in c.get("sources", []) or []:
                if not re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9._-]+", r):
                    out.append(f"{link['name']}: source `{r}` is not owner/name")
    return out


def fanout_owned(pr: dict, prefix: str) -> bool:
    """A PR the refresh may rebuild: on a fan-out branch, opened by the App, not from a fork."""
    return (pr.get("headRefName", "").startswith(prefix) and not pr.get("isCrossRepository")
            and (pr.get("author") or {}).get("login") == APP_AUTHOR)


class PinnedDigests:
    """A gateway whose digests come from an open fan-out PR, not the registry."""

    def __init__(self, gw, digests: dict):
        self._gw, self._digests = gw, digests

    def __getattr__(self, name):
        return getattr(self._gw, name)

    def resolve_digest(self, image: str, ref: str) -> str:
        if (image, ref) not in self._digests:
            raise FanoutError(f"refresh: the open PR holds no digest for {image}:{ref}")
        return self._digests[(image, ref)]


def refresh(manifest: dict, gw, dry_run: bool, work: str) -> int:
    """Rebuild every open fan-out PR whose branch is behind the consumer's main (.github#275).

    A fan-out PR is built from the main of its moment. When main moves, the
    generated files it regenerated (goldens, the image list) conflict. A rerun
    of the same value on current main is the rebase: it rewrites, regenerates
    and verifies again, and pushes the branch with a lease. The digest of an
    image pin is read from the open PR, so the image stays the one reviewed.
    """
    failures = 0
    for link in manifest.get("links", []):
        name = link["name"]
        prefix = f"chore/version-fanout-{name}-"
        by_repo: dict[str, list[dict]] = {}
        for c in link.get("consumers", []) or []:
            by_repo.setdefault(c["repo"], []).append(c)
        for repo, consumers in by_repo.items():
            for number, branch in gw.open_fanout_prs(repo, prefix):
                value = branch[len(prefix):]
                try:
                    behind = gw.behind_main(repo, branch)
                    if behind == 0:
                        continue
                    print(f"{repo}#{number}: {branch} is {behind} commit(s) behind main; rebuilding on main")
                    digests = {}
                    for c in consumers:
                        if c.get("image"):
                            pinned = read_key(gw.file_text(repo, c["file"], branch), "yaml", c["key"])
                            if "@" in pinned:
                                digests[(c["image"], value)] = pinned.split("@", 1)[1]
                    failures += fanout(manifest, name, PinnedDigests(gw, digests), value, "main", dry_run, work,
                                       only_repo=repo)
                except FanoutError as e:
                    failures += 1
                    print(f"::error::{repo}#{number}: {e}", file=sys.stderr)
    return 1 if failures else 0


def fanout(manifest: dict, link_name: str, gw, value: str | None, source_ref: str,
           dry_run: bool, work: str, only_repo: str | None = None) -> int:
    link = find_link(manifest, link_name)
    src = link["source"]
    if not value:
        value = read_key(gw.file_text(src["repo"], src["file"], source_ref), src["format"], src["key"])
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", value):
        raise FanoutError(f"refusing to fan out an unsafe value {value!r}")
    branch = f"chore/version-fanout-{link_name}-{value}"
    by_repo: dict[str, list[dict]] = {}
    for c in link.get("consumers", []):
        if only_repo is None or c["repo"] == only_repo:
            by_repo.setdefault(c["repo"], []).append(c)
    print(f"link {link_name}: source {src['repo']} = {value}; consumers in {len(by_repo)} repo(s)")
    failures = 0
    for repo, consumers in by_repo.items():
        dest = os.path.join(work, repo.replace("/", "__"))
        shutil.rmtree(dest, ignore_errors=True)
        try:
            gw.clone(repo, dest)
            clone_sources(work, consumers, value, gw)
            sh("git", "checkout", "-q", "-B", branch, cwd=dest)
            changes = [apply_consumer(dest, c, value, gw) for c in consumers]
            if not sh("git", "status", "--porcelain", cwd=dest).strip():
                print(f"{repo}: already at {value}; nothing to open")
                continue
            for c in consumers:
                sh("git", "add", "--", c["file"], cwd=dest)
            changes += regenerate(dest, repo, consumers, gw)
            verify(dest, repo, consumers, gw)
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
    def __init__(self, files: dict, digests: dict, open_prs: dict | None = None, fail_digest: bool = False,
                 sources: dict | None = None, behind: dict | None = None, branch_files: dict | None = None):
        self.files, self.digests, self.open_prs = files, digests, open_prs or {}
        self.fail_digest = fail_digest
        self.sources = sources or {}          # (repo, tag) -> {path: text}
        self.behind = behind or {}            # (repo, branch) -> commits behind main
        self.branch_files = branch_files or {}  # (repo, path, ref) -> text
        self.helm: dict = {}                  # version -> (tarball bytes, published sha256)
        self.calls: list[tuple] = []

    def file_text(self, repo, path, ref):
        if (repo, path, ref) in self.branch_files:
            return self.branch_files[(repo, path, ref)]
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

    def clone_source(self, repo, tag, dest):
        if (repo, tag) not in self.sources:
            raise FanoutError(f"source {repo} has no tag {tag}")
        os.makedirs(dest, exist_ok=True)
        sh("git", "init", "-q", dest)
        sh("git", "config", "user.name", "t", cwd=dest); sh("git", "config", "user.email", "t@t", cwd=dest)
        for path, text in self.sources[(repo, tag)].items():
            full = os.path.join(dest, path); os.makedirs(os.path.dirname(full), exist_ok=True)
            open(full, "w").write(text)
        sh("git", "add", "-A", cwd=dest); sh("git", "commit", "-q", "-m", tag, cwd=dest); sh("git", "tag", tag, cwd=dest)
        sh("git", "remote", "add", "origin", f"https://github.com/{repo}.git", cwd=dest)
        self.calls.append(("clone_source", repo, tag))

    def open_fanout_prs(self, repo, prefix):
        return [(n, b) for (r, b), n in self.open_prs.items() if r == repo and b.startswith(prefix)]

    def behind_main(self, repo, branch):
        n = self.behind.get((repo, branch), 0)
        if n < 0:
            raise FanoutError(f"compare main...{branch}: mocked 404")
        return n

    def helm_release(self, version):
        self.calls.append(("helm_release", version))
        return self.helm[version]

    def helm_login(self, helm):
        self.calls.append(("helm_login", helm))


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


# The reusable workflow must not install a Helm of its own. A pinned copy
# drifted from the Helm the consumer requires (v3.16.2 against v4.2.1) and
# failed every charts fan-out. The fan-out reads it from the consumer instead.
FANOUT_WORKFLOWS = [os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".github", "workflows", f)
                    for f in ("reusable-version-fanout.yml", "version-fanout-refresh.yml")]
# Keyed to Helm names only. A bare `version:` input of another action must not
# trip it, or the guard would need a change for an edit that has no Helm in it.
HELM_PIN_RE = re.compile(r"setup-helm|get\.helm\.sh|helm-v\d|HELM_VERSION")


def workflow_pins_helm(text: str) -> bool:
    """True when a workflow text installs or names a Helm version of its own.

    Comment lines do not count: a comment may tell the history of the pin.
    """
    code = "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))
    return bool(HELM_PIN_RE.search(code))


def fixture_helm(version: str) -> tuple[bytes, str]:
    """A Helm release tarball whose `helm` prints its version, and its SHA-256."""
    buf = io.BytesIO()
    script = f'#!/bin/sh\necho "fixture-helm {version} $*"\n'.encode()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        info = tarfile.TarInfo("linux-amd64/helm"); info.size = len(script); info.mode = 0o755
        t.addfile(info, io.BytesIO(script))
    data = buf.getvalue()
    return data, hashlib.sha256(data).hexdigest()


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
    dotted = 'neo4j:\n  config:\n    dbms.security.procedures.allowlist: "apoc.merge.node"\n'
    t2 = set_yaml_scalar(dotted, "neo4j.config.dbms\\.security\\.procedures\\.allowlist", "apoc.merge.node,apoc.merge.relationship")
    check('dbms.security.procedures.allowlist: "apoc.merge.node,apoc.merge.relationship"' in t2, "an escaped dot rewrites a dotted yaml key")
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
        check("auto-merge" in charts_body.lower(), "PR body says no auto-merge")
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
    # 8. a consumer's `regenerate` commands run in the clone and their tracked output joins the commit
    with tempfile.TemporaryDirectory() as w:
        m = json.loads(json.dumps(MANIFEST))
        m["links"][0]["consumers"][0]["regenerate"] = ["wc -l < helm/values.yaml > derived/lines.txt"]
        m["links"][0]["consumers"][1]["regenerate"] = ["wc -l < helm/values.yaml > derived/lines.txt"]  # same command twice: runs once
        f2 = dict(files); f2[("o/charts", "derived/lines.txt")] = "stale\n"
        gw = FixtureGateway(f2, {("zitadel-login", "v4.17.3"): DIG})
        rc = fanout(m, "zitadel", gw, None, "main", False, w)
        committed = sh("git", "show", "--name-only", "--format=", "HEAD", cwd=os.path.join(w, "o__charts")).split()
        check(rc == 0 and "derived/lines.txt" in committed and "helm/values.yaml" in committed, "regenerated tracked file is in the fan-out commit")
        check(open(os.path.join(w, "o__charts", "derived/lines.txt")).read().strip() != "stale", "the regenerate command actually ran")
        body = [c[4] for c in gw.calls if c[0] == "create" and c[1] == "o/charts"][0]
        check("derived/lines.txt (regenerated)" in body, "PR body names the regenerated file")
    # 8b. a regenerate command never sees the fan-out's tokens. The command is
    #     the consumer's own code, and the token can push to every consumer.
    with tempfile.TemporaryDirectory() as w:
        m = json.loads(json.dumps(MANIFEST))
        m["links"][0]["consumers"][0]["regenerate"] = ["env | sort > derived/env.txt"]
        f2 = dict(files); f2[("o/charts", "derived/env.txt")] = "stale\n"
        gw = FixtureGateway(f2, {("zitadel-login", "v4.17.3"): DIG})
        saved = {k: os.environ.get(k) for k in FANOUT_TOKENS}
        os.environ.update(GH_TOKEN="fixture-app-token", GITHUB_TOKEN="fixture-github-token", GHCR_TOKEN="fixture-ghcr-token")
        try:
            rc = fanout(m, "zitadel", gw, None, "main", False, w)
        finally:
            for k, v in saved.items():
                if v is None: os.environ.pop(k, None)
                else: os.environ[k] = v
        seen = open(os.path.join(w, "o__charts", "derived/env.txt")).read()
        check(rc == 0 and "PATH=" in seen, "the regenerate command ran with an environment")
        check("fixture-app-token" not in seen and "fixture-github-token" not in seen and "fixture-ghcr-token" not in seen
              and not any(ln.split("=", 1)[0] in FANOUT_TOKENS for ln in seen.splitlines()),
              "no fan-out token is visible to the regenerate command")
    # 8c. the consumer names its Helm in scripts/golden.sh. The fan-out installs
    #     that version, checks its published SHA-256, logs it in to ghcr.io,
    #     and puts it first on PATH for regenerate and verify.
    with tempfile.TemporaryDirectory() as w:
        _HELM_DIRS.clear()
        m = json.loads(json.dumps(MANIFEST))
        m["links"][0]["consumers"][0]["regenerate"] = ["helm version > derived/helm.txt"]
        m["links"][0]["consumers"][0]["verify"] = ["helm version | grep -q 'fixture-helm v9.9.9'"]
        f2 = dict(files); f2[("o/charts", "derived/helm.txt")] = "stale\n"
        f2[("o/charts", "scripts/golden.sh")] = '#!/bin/sh\nGOLDEN_HELM_VERSION="v9.9.9"\n'
        gw = FixtureGateway(f2, {("zitadel-login", "v4.17.3"): DIG})
        gw.helm["v9.9.9"] = fixture_helm("v9.9.9")
        rc = fanout(m, "zitadel", gw, None, "main", False, w)
        seen = open(os.path.join(w, "o__charts", "derived/helm.txt")).read()
        check(rc == 0 and "fixture-helm v9.9.9" in seen, "regenerate runs the Helm that the consumer's golden.sh names")
        check(("helm_release", "v9.9.9") in gw.calls and any(c[0] == "helm_login" for c in gw.calls),
              "the fan-out fetched that Helm release and logged it in to ghcr.io")
        check(any(c[0] == "create" and c[1] == "o/charts" for c in gw.calls), "the consumer with a named Helm gets its PR")
    # 8d. a download that does not match its published SHA-256 is refused, and nothing opens for that repo
    with tempfile.TemporaryDirectory() as w:
        _HELM_DIRS.clear()
        m = json.loads(json.dumps(MANIFEST))
        m["links"][0]["consumers"][0]["regenerate"] = ["helm version > derived/helm.txt"]
        f2 = dict(files); f2[("o/charts", "derived/helm.txt")] = "stale\n"
        f2[("o/charts", "scripts/golden.sh")] = 'GOLDEN_HELM_VERSION="v9.9.9"\n'
        gw = FixtureGateway(f2, {("zitadel-login", "v4.17.3"): DIG})
        tarball, _ = fixture_helm("v9.9.9")
        gw.helm["v9.9.9"] = (tarball, "0" * 64)
        rc = fanout(m, "zitadel", gw, None, "main", False, w)
        check(rc == 1 and not any(c[0] == "create" and c[1] == "o/charts" for c in gw.calls),
              "a Helm download with the wrong SHA-256 is refused and opens nothing")
        check(not any(c[0] == "helm_login" for c in gw.calls), "an unverified Helm is never logged in")
    # 8e. a consumer that names no Helm installs none
    with tempfile.TemporaryDirectory() as w:
        _HELM_DIRS.clear()
        m = json.loads(json.dumps(MANIFEST))
        m["links"][0]["consumers"][0]["regenerate"] = ["wc -l < helm/values.yaml > derived/lines.txt"]
        f2 = dict(files); f2[("o/charts", "derived/lines.txt")] = "stale\n"
        gw = FixtureGateway(f2, {("zitadel-login", "v4.17.3"): DIG})
        rc = fanout(m, "zitadel", gw, None, "main", False, w)
        check(rc == 0 and not any(c[0] == "helm_release" for c in gw.calls), "a consumer that names no Helm installs none")
    # 8f. the reusable workflow installs no Helm of its own. The planted copy is
    #     the step that drifted to v3.16.2 while charts required v4.2.1.
    planted = ("      - uses: azure/setup-helm@9bc31f4ebc9c6b171d7bfbaa5d006ae7abdb4310 # v5\n"
               "        with:\n          version: v3.16.2\n")
    check(workflow_pins_helm(planted), "the guard catches a workflow that pins its own Helm (planted fixture)")
    check(workflow_pins_helm('        env:\n          HELM_VERSION: "v4.2.1"\n'), "the guard catches a HELM_VERSION literal (planted fixture)")
    check(not workflow_pins_helm("      - uses: actions/setup-node@abc # v6\n        with:\n          version: 22.11.0\n"),
          "the guard ignores a version input of an action that is not Helm")
    for wf in FANOUT_WORKFLOWS:
        check(os.path.isfile(wf) and not workflow_pins_helm(open(wf).read()),
              f"{os.path.basename(wf)} installs no Helm of its own; the consumer names it")
    # 9. regenerate that leaves untracked output, or fails, is loud and opens nothing for that repo
    with tempfile.TemporaryDirectory() as w:
        m = json.loads(json.dumps(MANIFEST))
        m["links"][0]["consumers"][0]["regenerate"] = ["echo x > new-file.txt"]
        gw = FixtureGateway(files, {("zitadel-login", "v4.17.3"): DIG})
        rc = fanout(m, "zitadel", gw, None, "main", False, w)
        check(rc == 1 and not any(c[0] == "create" and c[1] == "o/charts" for c in gw.calls), "untracked regenerate output is refused")
    with tempfile.TemporaryDirectory() as w:
        m = json.loads(json.dumps(MANIFEST))
        m["links"][0]["consumers"][0]["regenerate"] = ["exit 3"]
        gw = FixtureGateway(files, {("zitadel-login", "v4.17.3"): DIG})
        rc = fanout(m, "zitadel", gw, None, "main", False, w)
        check(rc == 1 and not any(c[0] == "create" and c[1] == "o/charts" for c in gw.calls), "a failing regenerate command is loud")
    # 10. push_with_lease against a real bare remote: first push creates, a rerun from a fresh shallow
    #     clone updates the bot branch, and a branch moved by someone else is refused
    with tempfile.TemporaryDirectory() as w:
        bare = os.path.join(w, "origin.git"); sh("git", "init", "-q", "--bare", bare)
        seed = os.path.join(w, "seed"); sh("git", "init", "-q", seed)
        sh("git", "config", "user.name", "t", cwd=seed); sh("git", "config", "user.email", "t@t", cwd=seed)
        open(os.path.join(seed, "f"), "w").write("1\n"); sh("git", "add", "f", cwd=seed); sh("git", "commit", "-q", "-m", "base", cwd=seed)
        sh("git", "push", "-q", bare, "HEAD:refs/heads/main", cwd=seed)
        def fresh(name):
            d = os.path.join(w, name); sh("git", "clone", "-q", "--depth", "50", "-b", "main", bare, d)
            sh("git", "config", "user.name", "t", cwd=d); sh("git", "config", "user.email", "t@t", cwd=d)
            sh("git", "checkout", "-q", "-B", "chore/version-fanout-x-v1", cwd=d)
            open(os.path.join(d, "f"), "a").write(name + "\n"); sh("git", "commit", "-q", "-am", name, cwd=d); return d
        d1 = fresh("first"); push_with_lease(d1, "chore/version-fanout-x-v1"); check(True, "first push creates the bot branch")
        d2 = fresh("rerun"); push_with_lease(d2, "chore/version-fanout-x-v1")
        tip = sh("git", "--git-dir", bare, "log", "-1", "--format=%s", "chore/version-fanout-x-v1").strip()
        check(tip == "rerun", "a rerun from a fresh shallow clone replaces the bot branch")
        # A lease that names a tip the remote no longer holds (a race between
        # fetch and push) is refused by git, so a rerun can never clobber a
        # branch someone else moved.
        d3 = fresh("stale")
        wrong = sh("git", "rev-parse", "HEAD~1", cwd=d3).strip()
        r = subprocess.run(["git", "push", "--force-with-lease=refs/heads/chore/version-fanout-x-v1:" + wrong, "-q", "origin", "chore/version-fanout-x-v1"], cwd=d3, capture_output=True, text=True)
        check(r.returncode != 0 and "stale info" in (r.stderr + r.stdout).lower(), "a lease that names the wrong tip is refused")
    # 11-13. .github#275: a chart pin whose service has a vendored contract.
    #     The fixture chart pins docs-site in values.yaml, derives the pinned
    #     tag into images.txt, and holds a contract that must name that tag.
    #     check.sh is the consumer gate (charts `contract-pins`).
    contract_files = {
        ("o/site", "image-tag.env"): "TAG=v2\n",
        ("o/charts", "helm/values.yaml"): 'docs:\n  image:\n    tag: "v1@' + "sha256:" + "c" * 64 + '"\n',
        ("o/charts", "images.txt"): "docs-site:v1\n",
        ("o/charts", "contracts/docs-site.txt"): "# Source: o/site @ v1\nDOCS_A\n",
        ("o/charts", "check.sh"): 'pin=$(sed "s/.*://" images.txt); grep -q "@ $pin\\$" contracts/docs-site.txt\n',
        ("o/charts", "gen.sh"): 'pin=$(sed "s/.*://" images.txt); { echo "# Source: o/site @ $pin"; cat ../site/readers.txt; } > contracts/docs-site.txt\n',
    }
    site_v2 = {("o/site", "v2"): {"readers.txt": "DOCS_A\nDOCS_B\n"}}
    def contract_manifest(regen, sources, verify_cmds):
        return {"version": 1, "links": [{"name": "docs-site",
            "source": {"repo": "o/site", "file": "image-tag.env", "key": "TAG", "format": "env"},
            "consumers": [{"repo": "o/charts", "file": "helm/values.yaml", "key": "docs.image.tag", "format": "yaml",
                           "before": "@", "image": "docs-site", "regenerate": regen, "sources": sources,
                           "verify": verify_cmds}]}]}
    image_list = "sed -n 's/.*tag: \"\\(v[0-9]*\\)@.*/docs-site:\\1/p' helm/values.yaml > images.txt"
    # 11. no contract regeneration: the verify step fails, and nothing is pushed or opened
    with tempfile.TemporaryDirectory() as w:
        gw = FixtureGateway(contract_files, {("docs-site", "v2"): DIG}, sources=site_v2)
        rc = fanout(contract_manifest([image_list], [], ["sh check.sh"]), "docs-site", gw, None, "main", False, w)
        check(rc == 1 and not any(c[0] in ("push", "create") for c in gw.calls),
              "a chart pin that leaves its vendored contract at the old tag fails verify and opens nothing")
    # 12. sources + contract regeneration: the source is cloned beside the chart, the contract moves, verify passes
    with tempfile.TemporaryDirectory() as w:
        gw = FixtureGateway(contract_files, {("docs-site", "v2"): DIG}, sources=site_v2)
        rc = fanout(contract_manifest([image_list, "sh gen.sh"], ["o/site"], ["sh check.sh"]), "docs-site", gw, None, "main", False, w)
        contract = open(os.path.join(w, "o__charts", "contracts/docs-site.txt")).read()
        committed = sh("git", "show", "--name-only", "--format=", "HEAD", cwd=os.path.join(w, "o__charts")).split()
        check(rc == 0 and "# Source: o/site @ v2" in contract and "DOCS_B" in contract,
              "the contract is regenerated from the source at the released tag")
        check("contracts/docs-site.txt" in committed and any(c[0] == "create" for c in gw.calls),
              "the regenerated contract is in the fan-out commit, and the PR opens")
        check(("clone_source", "o/site", "v2") in gw.calls, "the source is cloned at the fanned-out value")
        url = sh("git", "config", "--get", "remote.origin.url", cwd=os.path.join(w, "site")).strip()
        check(url == "https://github.com/o/site.git", "the source clone keeps no token in its remote")
    # 13. the manifest rule: a charts image pin with no contract check is refused
    bad = contract_manifest([image_list], [], [])
    bad["links"][0]["consumers"][0]["repo"] = "zeroroot-ai/charts"
    check(manifest_problems(bad) != [], "a charts image pin with no `pinned_source.py --check-headers` verify is refused")
    real_m = yaml_to_json(open(os.path.join(os.path.dirname(__file__), "..", "version-links.yaml")).read())
    check(manifest_problems(real_m) == [], "the real version-links.yaml passes the manifest rules")
    # 14. --refresh: an open fan-out PR behind main is rebuilt on main with the digest of the PR; one at main is left
    fanout_branch = "chore/version-fanout-docs-site-v2"
    pr_values = 'docs:\n  image:\n    tag: "v2@' + "sha256:" + "d" * 64 + '"\n'
    with tempfile.TemporaryDirectory() as w:
        gw = FixtureGateway(contract_files, {}, sources=site_v2, open_prs={("o/charts", fanout_branch): 7},
                            behind={("o/charts", fanout_branch): 3},
                            branch_files={("o/charts", "helm/values.yaml", fanout_branch): pr_values})
        rc = refresh(contract_manifest([image_list, "sh gen.sh"], ["o/site"], ["sh check.sh"]), gw, False, w)
        after = open(os.path.join(w, "o__charts", "helm/values.yaml")).read()
        check(rc == 0 and ("push", fanout_branch) in gw.calls and any(c[0] == "edit" and c[2] == 7 for c in gw.calls),
              "a fan-out PR behind main is rebuilt and pushed, and the PR is edited in place")
        check("sha256:" + "d" * 64 in after, "the rebuilt PR keeps the digest of the open PR (no registry read)")
    with tempfile.TemporaryDirectory() as w:
        gw = FixtureGateway(contract_files, {}, sources=site_v2, open_prs={("o/charts", fanout_branch): 7})
        rc = refresh(contract_manifest([image_list, "sh gen.sh"], ["o/site"], ["sh check.sh"]), gw, False, w)
        check(rc == 0 and not gw.calls, "a fan-out PR at main is left as it is")
    # 15. refresh rebuilds only the App's own PRs, and one failing compare does not stop the run
    p = "chore/version-fanout-docs-site-"
    check(fanout_owned({"headRefName": p + "v2", "author": {"login": APP_AUTHOR}, "isCrossRepository": False}, p),
          "a fan-out PR the App opened is the refresh's to rebuild")
    check(not fanout_owned({"headRefName": p + "v2", "author": {"login": "someone"}, "isCrossRepository": False}, p),
          "a PR by another author on a fan-out branch name is left alone")
    check(not fanout_owned({"headRefName": p + "v2", "author": {"login": APP_AUTHOR}, "isCrossRepository": True}, p),
          "a PR from a fork is left alone")
    with tempfile.TemporaryDirectory() as w:
        gone = "chore/version-fanout-docs-site-v1"
        gw = FixtureGateway(contract_files, {}, sources=site_v2,
                            open_prs={("o/charts", gone): 6, ("o/charts", fanout_branch): 7},
                            behind={("o/charts", gone): -1, ("o/charts", fanout_branch): 3},
                            branch_files={("o/charts", "helm/values.yaml", fanout_branch): pr_values})
        rc = refresh(contract_manifest([image_list, "sh gen.sh"], ["o/site"], ["sh check.sh"]), gw, False, w)
        check(rc == 1 and ("push", fanout_branch) in gw.calls,
              "a failing compare for one PR is loud, and the next PR is still rebuilt")
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
    ap.add_argument("--refresh", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.link and not a.refresh:
        ap.error("--link or --refresh is required")
    token = os.environ.get("GH_TOKEN") or sh("gh", "auth", "token").strip()
    gw = Gateway(token, os.environ.get("GHCR_TOKEN") or token)
    manifest = yaml_to_json(open(a.manifest).read())
    work = a.work or tempfile.mkdtemp(prefix="version-fanout-")
    problems = manifest_problems(manifest)
    if problems:
        for p in problems:
            print(f"::error::{p}", file=sys.stderr)
        return 1
    try:
        if a.refresh:
            return refresh(manifest, gw, a.dry_run, work)
        return fanout(manifest, a.link, gw, a.value, a.source_ref, a.dry_run, work)
    except FanoutError as e:
        print(f"::error::{e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
