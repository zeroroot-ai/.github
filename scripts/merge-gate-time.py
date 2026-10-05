#!/usr/bin/env python3
"""Report the time of the merge gate for each repo.

The merge gate has a budget of ten minutes (ADR-0080). This report shows, for
each repo, how long the REQUIRED checks of its merged pull requests took: the
time from the first start to the last end. It marks each repo whose median is
above the budget.

Ten minutes is a number that the report shows. The report opens no issue and
fails no check on a pull request (owner decision of 2026-10-05, D35). It
writes to the summary of its own workflow run.

HOW IT MEASURES

  1. The required check names of a repo come from the rules of its default
     branch. A repo with no required check is listed with that statement.
  2. For each pull request that merged in the period, the report reads the
     check runs of its head commit and keeps the required ones.
  3. The gate time of the pull request is last end minus first start. When a
     check ran more than one time, each run counts, so a rerun makes the time
     longer. That is the time that the author waited.

USAGE

  READ_TOKEN=<token> python3 scripts/merge-gate-time.py [--days 7] [--per-repo 15]
  python3 scripts/merge-gate-time.py --selftest

The run fails when it reads no merged pull request in the organization, so an
empty report never looks correct.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import statistics
import subprocess
import sys

ORG = "zeroroot-ai"
BUDGET_MINUTES = 10.0


def parse(stamp: str) -> dt.datetime:
    return dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def gate_minutes(check_runs: list[dict], required: set[str]) -> float | None:
    """Minutes from the first start to the last end of the required checks.

    Returns None when no required check has both a start and an end.
    """
    starts, ends = [], []
    for run in check_runs:
        if run.get("name") not in required:
            continue
        if not run.get("started_at") or not run.get("completed_at"):
            continue
        starts.append(parse(run["started_at"]))
        ends.append(parse(run["completed_at"]))
    if not starts:
        return None
    return max(0.0, (max(ends) - min(starts)).total_seconds() / 60.0)


def summarize(repo: str, required: set[str], times: list[float]) -> dict:
    row = {"repo": repo, "required": len(required), "count": len(times),
           "median": None, "longest": None, "over": False}
    if times:
        row["median"] = statistics.median(times)
        row["longest"] = max(times)
        row["over"] = row["median"] > BUDGET_MINUTES
    return row


def render(rows: list[dict], days: int, now: dt.datetime) -> str:
    measured = [r for r in rows if r["count"]]
    if not measured:
        raise ValueError("the run measured no merged pull request")
    total = sum(r["count"] for r in measured)
    over = [r for r in measured if r["over"]]
    out = [
        "# Time of the merge gate",
        "",
        f"Period: the last {days} days before {now.strftime('%Y-%m-%d %H:%M')} UTC. "
        f"The budget is {BUDGET_MINUTES:.0f} minutes (ADR-0080).",
        "",
        f"The run measured {total} merged pull requests in {len(measured)} repos. "
        f"{len(over)} repo(s) have a median above the budget.",
        "",
        "The time of one pull request is the time from the first start to the last end of its required checks.",
        "",
        "| Repo | Required checks | Pull requests | Median, minutes | Longest, minutes | Above the budget |",
        "|---|---|---|---|---|---|",
    ]
    for r in sorted(measured, key=lambda r: (-r["median"], r["repo"])):
        mark = "YES" if r["over"] else "no"
        out.append(f"| {r['repo']} | {r['required']} | {r['count']} | {r['median']:.1f} | {r['longest']:.1f} | {mark} |")
    rest = sorted((r for r in rows if not r["count"]), key=lambda r: r["repo"])
    if rest:
        out += ["", "Not measured:", ""]
        for r in rest:
            why = "no required check" if not r["required"] else "no merged pull request with a required check in the period"
            out.append(f"- {r['repo']}: {why}")
    return "\n".join(out) + "\n"


# --- GitHub ------------------------------------------------------------------

def gh_lines(path: str, jq: str, token: str) -> list | None:
    """Run one paginated read. The jq filter must print one JSON object for each line."""
    p = subprocess.run(["gh", "api", "--paginate", path, "--jq", jq], capture_output=True, text=True,
                       env=dict(os.environ, GH_TOKEN=token), check=False)
    if p.returncode != 0:
        return None
    return [json.loads(line) for line in p.stdout.splitlines() if line.strip()]


def measure_org(token: str, days: int, per_repo: int, now: dt.datetime) -> list[dict]:
    repos = gh_lines(f"orgs/{ORG}/repos?per_page=100&type=all", ".[] | select(.archived | not) | "
                     "{name, default_branch}", token)
    if not repos:
        raise SystemExit("merge-gate-time: the run did not read the list of repos")
    since = now - dt.timedelta(days=days)
    rows = []
    for repo in sorted(repos, key=lambda r: r["name"]):
        name = repo["name"]
        contexts = gh_lines(f"repos/{ORG}/{name}/rules/branches/{repo['default_branch']}",
                            '.[] | select(.type == "required_status_checks") | '
                            "{context: .parameters.required_status_checks[].context}", token)
        required = {c["context"] for c in contexts or []}
        times: list[float] = []
        if required:
            pulls = gh_lines(f"repos/{ORG}/{name}/pulls?state=closed&sort=updated&direction=desc&per_page=50",
                             ".[] | select(.merged_at != null) | {merged_at, sha: .head.sha}", token) or []
            recent = [p for p in pulls if parse(p["merged_at"]) >= since][:per_repo]
            for pull in recent:
                runs = gh_lines(f"repos/{ORG}/{name}/commits/{pull['sha']}/check-runs?per_page=100",
                                ".check_runs[] | {name, started_at, completed_at}", token) or []
                minutes = gate_minutes(runs, required)
                if minutes is not None:
                    times.append(minutes)
        rows.append(summarize(name, required, times))
    return rows


# --- self-test ---------------------------------------------------------------

def selftest() -> int:
    failures = []

    def expect(name, ok):
        if not ok:
            failures.append(name)

    def run(name, start, end):
        return {"name": name, "started_at": start, "completed_at": end}

    required = {"lint", "test"}
    eleven = [run("lint", "2026-10-05T10:00:00Z", "2026-10-05T10:02:00Z"),
              run("test", "2026-10-05T10:00:30Z", "2026-10-05T10:11:00Z"),
              run("optional", "2026-10-05T09:00:00Z", "2026-10-05T12:00:00Z")]
    four = [run("lint", "2026-10-05T10:00:00Z", "2026-10-05T10:04:00Z"),
            run("test", "2026-10-05T10:00:00Z", "2026-10-05T10:03:00Z")]
    expect("the time is last end minus first start", gate_minutes(eleven, required) == 11.0)
    expect("a check that is not required does not count", gate_minutes(eleven, {"lint"}) == 2.0)
    expect("a check with no end does not count",
           gate_minutes([run("lint", "2026-10-05T10:00:00Z", None)], required) is None)
    expect("no required check gives no time", gate_minutes(four, {"other"}) is None)

    now = dt.datetime(2026, 10, 5, 12, 0, tzinfo=dt.timezone.utc)
    slow = summarize("slow", required, [gate_minutes(eleven, required)] * 3)
    fast = summarize("fast", required, [gate_minutes(four, required), 4.0, 30.0])
    none = summarize("none", set(), [])
    idle = summarize("idle", required, [])
    text = render([slow, fast, none, idle], 7, now)
    # The fixture of the issue: check runs that take eleven minutes mark the repo.
    expect("a repo with eleven minutes is marked", "| slow | 2 | 3 | 11.0 | 11.0 | YES |" in text)
    expect("a repo with a median of four minutes is not marked", "| fast | 2 | 3 | 4.0 | 30.0 | no |" in text)
    expect("the slowest repo is first", text.index("| slow |") < text.index("| fast |"))
    expect("the count is stated", "measured 6 merged pull requests in 2 repos. 1 repo(s)" in text)
    expect("a repo with no required check is listed", "- none: no required check" in text)
    expect("a repo with no merged pull request is listed", "- idle: no merged pull request" in text)
    expect("exactly ten minutes is inside the budget", summarize("x", required, [10.0])["over"] is False)
    try:
        render([none, idle], 7, now)
        expect("a run that measured nothing fails", False)
    except ValueError:
        pass
    if failures:
        for f in failures:
            print(f"merge-gate-time: selftest FAILED: {f}", file=sys.stderr)
        return 1
    print("merge-gate-time: selftest OK (12 cases)")
    return 0


def main(argv: list[str]) -> int:
    args = argv[1:]
    if args == ["--selftest"]:
        return selftest()
    days, per_repo = 7, 15
    while args:
        if args[0] == "--days" and len(args) > 1:
            days, args = int(args[1]), args[2:]
        elif args[0] == "--per-repo" and len(args) > 1:
            per_repo, args = int(args[1]), args[2:]
        else:
            print(__doc__, file=sys.stderr)
            return 2
    token = os.environ.get("READ_TOKEN") or os.environ.get("GH_TOKEN", "")
    if not token:
        print("merge-gate-time: set READ_TOKEN or GH_TOKEN", file=sys.stderr)
        return 2
    now = dt.datetime.now(dt.timezone.utc)
    rows = measure_org(token, days, per_repo, now)
    try:
        text = render(rows, days, now)
    except ValueError as e:
        print(f"merge-gate-time: {e}", file=sys.stderr)
        return 1
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
