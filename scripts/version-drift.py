#!/usr/bin/env python3
"""version-drift.py — compare every link in version-links.yaml and keep ONE tracker issue.

Epic zeroroot-ai/.github#20. Behavior contract (proved by `--selftest`, which
gates the scheduled job in .github/workflows/version-drift.yml):

  * One tracker issue, found by the stable title prefix and edited in place.
    Never a second one, even when several links drift in the same run.
  * Zero drift CLOSES the open tracker with a dated comment. The next drift
    opens a fresh one, so the issue history reads as episodes, not as one
    eternal thread.
  * An API error or a missing file is an ERROR row. ERROR rows are printed,
    turn the run red, and are never filed: the tracker only ever carries
    values the script actually read (the sarif-triage rule).
  * "upstream ahead" is drift: the source must move, or a human must record
    why it does not. Only non-prerelease, non-draft releases count, and
    "newest" is the highest semver, not the first in the feed (zitadel
    publishes a v3 maintenance line next to v4). The compare runs at the
    precision of the source: a floating `3.6` is in sync with `v3.6.4`.
  * A `subchart` block adds one informational row: the appVersion the pinned
    Helm dependency ships, read from the chart repository's index.yaml. It
    is never drift; it says how far the override sits from the tested app.
  * A consumer with `after` compares the part of the value after the last
    occurrence of that string (inline `registry/name:tag` references).

Reads YAML through `yq -o=json` (present on the GitHub runners and on the
workstation) so the script needs nothing beyond the Python standard library.

Usage:
  version-drift.py [--manifest version-links.yaml] [--tracker-repo OWNER/NAME] [--dry-run]
  version-drift.py --selftest
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

TITLE_PREFIX = "ci(version-drift): version links out of sync"
TRACKER_LABEL = "ready-for-agent"
OK, MISMATCH, UPSTREAM_AHEAD, ERROR = "OK", "MISMATCH", "UPSTREAM-AHEAD", "ERROR"
DRIFT_STATES = (MISMATCH, UPSTREAM_AHEAD)


class FetchError(Exception):
    """A value could not be read. Never filed; turns the run red."""


# --------------------------------------------------------------------------
# Gateways: the only place that talks to GitHub. The selftest swaps this for
# a fixture gateway that records every call.
class GitHubGateway:
    def _gh(self, *args: str) -> str:
        r = subprocess.run(["gh", *args], capture_output=True, text=True)
        if r.returncode != 0:
            raise FetchError(f"gh {' '.join(args[:3])}: {r.stderr.strip()[:300]}")
        return r.stdout

    def file_text(self, repo: str, path: str) -> str:
        out = self._gh("api", f"repos/{repo}/contents/{path}", "--jq", ".content")
        try:
            return base64.b64decode(out).decode()
        except Exception as e:  # noqa: BLE001
            raise FetchError(f"{repo}:{path}: not a file body ({e})") from e

    def releases(self, repo: str) -> list[dict]:
        out = self._gh("api", f"repos/{repo}/releases?per_page=100")
        data = json.loads(out)
        if not isinstance(data, list):
            raise FetchError(f"{repo}: releases response is not a list")
        return data

    def chart_index(self, url: str) -> dict:
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                return yaml_to_json(r.read().decode())
        except Exception as e:  # noqa: BLE001
            raise FetchError(f"{url}: {e}") from e

    def find_open_tracker(self, tracker_repo: str) -> int | None:
        out = self._gh(
            "issue", "list", "-R", tracker_repo, "--state", "open",
            "--search", f'in:title "{TITLE_PREFIX}"', "--json", "number,title",
        )
        for it in json.loads(out or "[]"):
            if it["title"].startswith(TITLE_PREFIX):
                return int(it["number"])
        return None

    def create_tracker(self, tracker_repo: str, title: str, body: str) -> str:
        try:
            return self._gh("issue", "create", "-R", tracker_repo, "--title", title,
                            "--body", body, "--label", TRACKER_LABEL).strip()
        except FetchError:
            return self._gh("issue", "create", "-R", tracker_repo, "--title", title,
                            "--body", body).strip()

    def edit_tracker(self, tracker_repo: str, number: int, title: str, body: str) -> None:
        self._gh("issue", "edit", str(number), "-R", tracker_repo, "--title", title, "--body", body)

    def close_tracker(self, tracker_repo: str, number: int, comment: str) -> None:
        self._gh("issue", "close", str(number), "-R", tracker_repo, "--comment", comment)


# --------------------------------------------------------------------------
# Value readers.
def yaml_to_json(text: str) -> dict:
    r = subprocess.run(["yq", "-o=json", "-I=0", "."], input=text, capture_output=True, text=True)
    if r.returncode != 0:
        raise FetchError(f"yq: {r.stderr.strip()[:200]}")
    return json.loads(r.stdout or "{}")


def read_key(text: str, fmt: str, key: str) -> str:
    if fmt == "env":
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            if k.strip() == key:
                return v.strip().strip('"').strip("'")
        raise FetchError(f"key {key} not found (env)")
    if fmt == "yaml":
        node = yaml_to_json(text)
        for part in key.split("."):
            if isinstance(node, list) and part.isdigit() and int(part) < len(node):
                node = node[int(part)]
            elif isinstance(node, dict) and part in node:
                node = node[part]
            else:
                raise FetchError(f"key {key} not found (yaml)")
        if not isinstance(node, (str, int, float)):
            raise FetchError(f"key {key} is not a scalar")
        return str(node)
    raise FetchError(f"unknown format {fmt}")


def semver_key(tag: str) -> tuple:
    core = tag.lstrip("vV").split("-")[0].split("+")[0]
    parts = []
    for p in core.split("."):
        parts.append(int(p) if p.isdigit() else -1)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)


def newest_release(releases: list[dict]) -> str | None:
    tags = [r["tag_name"] for r in releases
            if not r.get("prerelease") and not r.get("draft") and r.get("tag_name")]
    if not tags:
        return None
    return max(tags, key=semver_key)


def upstream_ahead(newest: str, source: str) -> bool:
    """Compare at the precision of the source: `3.6` vs `v3.6.4` is in sync."""
    precision = len(source.lstrip("vV").split("-")[0].split("+")[0].split("."))
    return semver_key(newest)[:precision] > semver_key(source)[:precision]


def subchart_app_version(link: dict, gw) -> tuple[str, str]:
    """(where, appVersion) for the Helm dependency a link's source overrides."""
    sc = link["subchart"]
    chart = yaml_to_json(gw.file_text(sc["repo"], sc["file"]))
    dep = next((d for d in chart.get("dependencies", [])
                if d.get("alias") == sc["name"] or d.get("name") == sc["name"]), None)
    if dep is None:
        raise FetchError(f"dependency {sc['name']} not in {sc['repo']}:{sc['file']}")
    repo_url = str(dep.get("repository", ""))
    if not repo_url.startswith("http"):
        raise FetchError(f"dependency {sc['name']}: repository {repo_url!r} has no index.yaml")
    version = str(dep.get("version", ""))
    where = f"{dep['name']}@{version} ({repo_url})"
    index = gw.chart_index(repo_url.rstrip("/") + "/index.yaml")
    entry = next((e for e in index.get("entries", {}).get(dep["name"], []) if str(e.get("version")) == version), None)
    if entry is None or not entry.get("appVersion"):
        raise FetchError(f"{where}: no appVersion in index.yaml")
    return where, str(entry["appVersion"])


# --------------------------------------------------------------------------
# Evaluation.
def evaluate(manifest: dict, gw) -> list[dict]:
    rows: list[dict] = []
    for link in manifest.get("links", []):
        name = link["name"]
        src = link["source"]
        where = f"{src['repo']}:{src['file']}:{src['key']}"
        try:
            src_val = read_key(gw.file_text(src["repo"], src["file"]), src["format"], src["key"])
        except FetchError as e:
            rows.append(dict(link=name, role="source", where=where, value="", state=ERROR, note=str(e)))
            continue
        rows.append(dict(link=name, role="source", where=where, value=src_val, state=OK, note=""))
        for c in link.get("consumers", []):
            cwhere = f"{c['repo']}:{c['file']}:{c['key']}"
            try:
                raw = read_key(gw.file_text(c["repo"], c["file"]), c["format"], c["key"])
            except FetchError as e:
                rows.append(dict(link=name, role="consumer", where=cwhere, value="", state=ERROR, note=str(e)))
                continue
            val = raw.split(c["before"], 1)[0] if c.get("before") else raw
            val = val.rsplit(c["after"], 1)[-1] if c.get("after") else val
            state = OK if val == src_val else MISMATCH
            note = "" if state == OK else f"source is {src_val}"
            rows.append(dict(link=name, role="consumer", where=cwhere, value=val, state=state, note=note))
        up = link.get("upstream")
        if up:
            try:
                newest = newest_release(gw.releases(up["repo"]))
            except FetchError as e:
                rows.append(dict(link=name, role="upstream", where=up["repo"], value="", state=ERROR, note=str(e)))
                continue
            if newest is None:
                rows.append(dict(link=name, role="upstream", where=up["repo"], value="", state=ERROR, note="no stable release"))
                continue
            ahead = upstream_ahead(newest, src_val)
            rows.append(dict(link=name, role="upstream", where=up["repo"], value=newest,
                             state=UPSTREAM_AHEAD if ahead else OK,
                             note=f"source is {src_val}" if ahead else ""))
        if link.get("subchart"):
            try:
                where, app = subchart_app_version(link, gw)
            except FetchError as e:
                rows.append(dict(link=name, role="subchart", where=link["subchart"]["name"], value="", state=ERROR, note=str(e)))
                continue
            if semver_key(src_val) == semver_key(app):
                note = "override equals the appVersion the chart ships"
            elif semver_key(src_val) > semver_key(app):
                note = f"override {src_val} is ahead of the appVersion the chart ships"
            else:
                note = f"override {src_val} is behind the appVersion the chart ships"
            rows.append(dict(link=name, role="subchart", where=where, value=app, state=OK, note=note))
    return rows


def render_body(rows: list[dict], today: str) -> str:
    drift = [r for r in rows if r["state"] in DRIFT_STATES]
    links = sorted({r["link"] for r in drift})
    out = [f"## Version links out of sync — {today}", "",
           f"{len(drift)} row(s) drift across {len(links)} link(s): {', '.join(links)}.", "",
           "| Link | Role | Where | Value | State | Note |", "|---|---|---|---|---|---|"]
    for r in rows:
        out.append(f"| `{r['link']}` | {r['role']} | `{r['where']}` | `{r['value']}` | **{r['state']}** | {r['note']} |")
    out += ["", "Fix: move the source, then let the fan-out open the consumer PRs, or edit the consumers to equal the source. "
            "Do not edit this issue by hand: `version-drift.yml` rewrites it daily from `version-links.yaml` "
            "and closes it when every link is in sync (zeroroot-ai/.github#20).",
            "", "_Auto-filed by version-drift.yml. One tracker issue, found by title and updated in place._"]
    return "\n".join(out)


def upsert(rows: list[dict], gw, tracker_repo: str, today: str, dry_run: bool = False) -> int:
    errors = [r for r in rows if r["state"] == ERROR]
    drift = [r for r in rows if r["state"] in DRIFT_STATES]
    for r in rows:
        print(f"{r['state']:<15} {r['link']:<12} {r['role']:<9} {r['where']} = {r['value']} {r['note']}")
    if errors:
        print(f"::error::{len(errors)} link value(s) could not be read; nothing filed", file=sys.stderr)
        return 1
    if dry_run:
        print(f"dry-run: {len(drift)} drift row(s); tracker untouched")
        return 0
    existing = gw.find_open_tracker(tracker_repo)
    if drift:
        links = sorted({r["link"] for r in drift})
        title = f"{TITLE_PREFIX} — {', '.join(links)}"
        body = render_body(rows, today)
        if existing:
            gw.edit_tracker(tracker_repo, existing, title, body)
            print(f"::notice::updated tracker #{existing}")
        else:
            url = gw.create_tracker(tracker_repo, title, body)
            print(f"::notice::opened tracker {url}")
        return 0
    if existing:
        gw.close_tracker(tracker_repo, existing, f"Every link in version-links.yaml is in sync as of {today}. Closed by version-drift.yml.")
        print(f"::notice::closed tracker #{existing}: all links in sync")
    else:
        print("all links in sync; nothing to file")
    return 0


# --------------------------------------------------------------------------
# Selftest: fixtures + mutations that prove every guard can fire.
class FixtureGateway:
    def __init__(self, files: dict, releases: dict, existing: int | None = None,
                 fail_files: set | None = None, fail_releases: set | None = None,
                 indexes: dict | None = None):
        self.files, self.rel, self.existing = files, releases, existing
        self.fail_files, self.fail_releases = fail_files or set(), fail_releases or set()
        self.indexes = indexes or {}
        self.calls: list[tuple] = []

    def chart_index(self, url):
        if url not in self.indexes:
            raise FetchError("HTTP 404 mocked index")
        return self.indexes[url]

    def file_text(self, repo, path):
        if (repo, path) in self.fail_files:
            raise FetchError("HTTP 500 mocked")
        try:
            return self.files[(repo, path)]
        except KeyError:
            raise FetchError("HTTP 404 mocked") from None

    def releases(self, repo):
        if repo in self.fail_releases:
            raise FetchError("HTTP 502 mocked")
        return self.rel.get(repo, [])

    def find_open_tracker(self, tracker_repo):
        self.calls.append(("find",))
        return self.existing

    def create_tracker(self, tracker_repo, title, body):
        self.calls.append(("create", title, body))
        return "https://github.com/mock/issues/1"

    def edit_tracker(self, tracker_repo, number, title, body):
        self.calls.append(("edit", number, title, body))

    def close_tracker(self, tracker_repo, number, comment):
        self.calls.append(("close", number, comment))


MANIFEST_FIXTURE = {
    "version": 1,
    "links": [{
        "name": "zitadel",
        "source": {"repo": "o/fork", "file": "UPSTREAM_REF", "key": "TAG", "format": "env"},
        "consumers": [
            {"repo": "o/charts", "file": "values.yaml", "key": "zitadel.image.tag", "format": "yaml"},
            {"repo": "o/charts", "file": "values.yaml", "key": "zitadel.login.image.tag", "format": "yaml", "before": "@"},
        ],
        "upstream": {"repo": "up/zitadel"},
    }],
}
UPSTREAM_REF = "# comment\nREPO=https://x\nTAG=v4.17.3\nCOMMIT=abc\n"
VALUES_OK = 'zitadel:\n  image:\n    tag: "v4.17.3"\n  login:\n    image:\n      tag: "v4.17.3@sha256:deadbeef"\n'
VALUES_BAD = 'zitadel:\n  image:\n    tag: "v4.14.0"\n  login:\n    image:\n      tag: "sha-f41ce75@sha256:deadbeef"\n'
REL_SAME = [{"tag_name": "v4.17.3"}, {"tag_name": "v3.4.15"}, {"tag_name": "v4.18.0", "prerelease": True},
            {"tag_name": "v5.0.0", "draft": True}]
REL_AHEAD = [{"tag_name": "v3.4.16"}, {"tag_name": "v4.17.4"}, {"tag_name": "v4.17.3"}]


def selftest() -> int:
    passed = failed = 0

    def check(cond: bool, name: str):
        nonlocal passed, failed
        print(("PASS: " if cond else "FAIL: ") + name)
        passed += cond
        failed += (not cond)

    files_ok = {("o/fork", "UPSTREAM_REF"): UPSTREAM_REF, ("o/charts", "values.yaml"): VALUES_OK}
    files_bad = {("o/fork", "UPSTREAM_REF"): UPSTREAM_REF, ("o/charts", "values.yaml"): VALUES_BAD}
    today = "2026-09-07"

    # 1. consumers drift -> exactly one tracker created, with both MISMATCH rows
    gw = FixtureGateway(files_bad, {"up/zitadel": REL_SAME})
    rows = evaluate(MANIFEST_FIXTURE, gw)
    rc = upsert(rows, gw, "o/.github", today)
    creates = [c for c in gw.calls if c[0] == "create"]
    check(rc == 0 and len(creates) == 1, "consumer drift files exactly one tracker")
    check(sum(r["state"] == MISMATCH for r in rows) == 2, "both chart consumers read as MISMATCH")
    check("v4.14.0" in creates[0][2] and "sha-f41ce75" in creates[0][2], "tracker body carries the consumer values")
    check(TITLE_PREFIX in creates[0][1], "tracker title carries the stable prefix")

    # 2. existing open tracker -> edited in place, never a second create
    gw = FixtureGateway(files_bad, {"up/zitadel": REL_SAME}, existing=7)
    upsert(evaluate(MANIFEST_FIXTURE, gw), gw, "o/.github", today)
    check([c[0] for c in gw.calls if c[0] in ("create", "edit")] == ["edit"], "existing tracker is edited, not duplicated")
    check(gw.calls[-1][1] == 7, "the edit targets the found issue number")

    # 3. image pin compares on the part before '@'; in-sync values read OK
    gw = FixtureGateway(files_ok, {"up/zitadel": REL_SAME})
    rows = evaluate(MANIFEST_FIXTURE, gw)
    check(all(r["state"] == OK for r in rows), "pin `v4.17.3@sha256:...` equals source v4.17.3; all OK")

    # 4. all in sync with an open tracker -> closed with a dated comment, no create
    gw = FixtureGateway(files_ok, {"up/zitadel": REL_SAME}, existing=9)
    upsert(evaluate(MANIFEST_FIXTURE, gw), gw, "o/.github", today)
    closes = [c for c in gw.calls if c[0] == "close"]
    check(len(closes) == 1 and closes[0][1] == 9 and today in closes[0][2], "in-sync run closes the open tracker with the date")
    check(not [c for c in gw.calls if c[0] == "create"], "in-sync run creates nothing")

    # 5. all in sync, no tracker -> nothing filed
    gw = FixtureGateway(files_ok, {"up/zitadel": REL_SAME})
    upsert(evaluate(MANIFEST_FIXTURE, gw), gw, "o/.github", today)
    check([c[0] for c in gw.calls] == ["find"], "in-sync run with no tracker touches nothing")

    # 6. upstream ahead is drift; newest is the semver max, not the first entry; prerelease/draft ignored
    gw = FixtureGateway(files_ok, {"up/zitadel": REL_AHEAD})
    rows = evaluate(MANIFEST_FIXTURE, gw)
    up = [r for r in rows if r["role"] == "upstream"][0]
    check(up["state"] == UPSTREAM_AHEAD and up["value"] == "v4.17.4", "upstream v4.17.4 ahead of source v4.17.3 (semver max over v3.4.16)")
    check(newest_release(REL_SAME) == "v4.17.3", "prerelease v4.18.0 and draft v5.0.0 are ignored")
    upsert(rows, gw, "o/.github", today)
    check(any(c[0] == "create" for c in gw.calls), "upstream-ahead files the tracker")

    # 7. source file missing -> ERROR, red, nothing filed
    gw = FixtureGateway({("o/charts", "values.yaml"): VALUES_OK}, {"up/zitadel": REL_SAME})
    rows = evaluate(MANIFEST_FIXTURE, gw)
    rc = upsert(rows, gw, "o/.github", today)
    check(rc == 1 and rows[0]["state"] == ERROR and not gw.calls, "missing source is an ERROR row, run red, no issue call")

    # 8. API error on releases -> ERROR, red, nothing filed (even with real drift present)
    gw = FixtureGateway(files_bad, {}, fail_releases={"up/zitadel"})
    rows = evaluate(MANIFEST_FIXTURE, gw)
    rc = upsert(rows, gw, "o/.github", today)
    check(rc == 1 and any(r["state"] == ERROR for r in rows) and not gw.calls, "release API error is never filed and turns the run red")

    # 9. hard safety: two drifting links in one run -> still ONE tracker
    two = json.loads(json.dumps(MANIFEST_FIXTURE))
    second = json.loads(json.dumps(two["links"][0]))
    second["name"] = "other"
    two["links"].append(second)
    gw = FixtureGateway(files_bad, {"up/zitadel": REL_SAME})
    upsert(evaluate(two, gw), gw, "o/.github", today)
    check(sum(c[0] == "create" for c in gw.calls) == 1, "two drifting links file ONE tracker")

    # 10. dry-run never touches the tracker
    gw = FixtureGateway(files_bad, {"up/zitadel": REL_SAME})
    upsert(evaluate(MANIFEST_FIXTURE, gw), gw, "o/.github", today, dry_run=True)
    check(not gw.calls, "dry-run makes no issue call")

    # 11. the real manifest parses; every link has a source and at least one of consumers/upstream/subchart
    real = yaml_to_json(open(os.path.join(os.path.dirname(__file__), "..", "version-links.yaml")).read())
    check(real.get("version") == 1 and real["links"] and all(
        l.get("source") and (l.get("consumers") or l.get("upstream") or l.get("subchart")) for l in real["links"]),
        "version-links.yaml parses and every link has a source and a consumer, upstream or subchart")

    # 12. `after` consumer: an inline image reference compares on the tag after the last ':'; list index keys read
    tools = {
        "version": 1,
        "links": [{
            "name": "alpine-k8s",
            "source": {"repo": "o/charts", "file": "values.yaml", "key": "zitadel.tools.kubectl.image.tag", "format": "yaml"},
            "consumers": [{"repo": "o/charts", "file": "values.yaml", "key": "zitadel.initContainers.0.image",
                           "format": "yaml", "after": ":"}],
        }],
    }
    vals = ('zitadel:\n  tools:\n    kubectl:\n      image:\n        tag: "1.33.0"\n'
            '  initContainers:\n    - name: wait\n      image: ghcr.io/o/mirror/alpine-k8s:1.31.0\n')
    rows = evaluate(tools, FixtureGateway({("o/charts", "values.yaml"): vals}, {}))
    cons = [r for r in rows if r["role"] == "consumer"][0]
    check(cons["state"] == MISMATCH and cons["value"] == "1.31.0", "`after: ':'` reads the tag of an inline image reference through a list index")
    vals_ok = vals.replace("alpine-k8s:1.31.0", "alpine-k8s:1.33.0")
    rows = evaluate(tools, FixtureGateway({("o/charts", "values.yaml"): vals_ok}, {}))
    check(all(r["state"] == OK for r in rows), "`after` consumer equal to the source reads OK")

    # 13. upstream compare at the precision of the source: floating minor `3.6`
    check(not upstream_ahead("v3.6.4", "3.6"), "source 3.6 is in sync with newest v3.6.4")
    check(upstream_ahead("v3.7.1", "3.6"), "source 3.6 is behind newest v3.7.1")
    check(upstream_ahead("v4.17.4", "v4.17.3") and not upstream_ahead("v4.17.3", "v4.17.3"), "full versions compare at patch precision")

    # 14. subchart row: informational, never drift; index failure is ERROR
    chart = ('dependencies:\n  - name: zitadel\n    alias: zitadel\n    version: "9.34.1"\n'
             '    repository: "https://charts.example"\n')
    index = {"entries": {"zitadel": [{"version": "9.34.1", "appVersion": "v4.13.1"}, {"version": "9.35.0", "appVersion": "v4.14.0"}]}}
    sub = json.loads(json.dumps(MANIFEST_FIXTURE))
    sub["links"][0]["subchart"] = {"repo": "o/charts", "file": "Chart.yaml", "name": "zitadel"}
    gw = FixtureGateway({**files_ok, ("o/charts", "Chart.yaml"): chart}, {"up/zitadel": REL_SAME},
                        indexes={"https://charts.example/index.yaml": index})
    rows = evaluate(sub, gw)
    scr = [r for r in rows if r["role"] == "subchart"][0]
    check(scr["state"] == OK and scr["value"] == "v4.13.1" and "ahead" in scr["note"], "subchart row reads appVersion v4.13.1 for the pinned 9.34.1 and says the override is ahead")
    upsert(rows, gw, "o/.github", today)
    check(not [c for c in gw.calls if c[0] == "create"], "a subchart distance alone files nothing")
    gw = FixtureGateway({**files_ok, ("o/charts", "Chart.yaml"): chart}, {"up/zitadel": REL_SAME})
    rows = evaluate(sub, gw)
    rc = upsert(rows, gw, "o/.github", today)
    check(rc == 1 and any(r["role"] == "subchart" and r["state"] == ERROR for r in rows), "unreachable chart index is an ERROR row and turns the run red")

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="version-links.yaml")
    ap.add_argument("--tracker-repo", default=os.environ.get("VERSION_DRIFT_TRACKER_REPO", "zeroroot-ai/.github"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    manifest = yaml_to_json(open(a.manifest).read())
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return upsert(evaluate(manifest, GitHubGateway()), GitHubGateway(), a.tracker_repo, today, a.dry_run)


if __name__ == "__main__":
    sys.exit(main())
