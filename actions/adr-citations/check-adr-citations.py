#!/usr/bin/env python3
"""check-adr-citations.py - each ADR citation in a repo names a live ADR.

The ADR records of the organization are private. One public index lists each
live ADR number with its rule, and each retired number. The source copy is
`docs/adr-index.md` in zeroroot-ai/gibson, and each other repo keeps a copy.

This guard reads the copy in the CALLING repository. It never fetches the
index, so a pull request is checked against the file that the repo holds.

WHAT IS A CITATION

  1. `ADR-` and then digits, in any tracked text file: ADR-0003.
  2. Four digits in double square brackets, in a Markdown file only: [[0003]].
     Other file types hold nested lists such as [[1024]] as data.

The guard takes the citation token and nothing else. It strips no prefix and
guesses no series. It does not match a token in these places:

  - Inside a URL. A URL is a word that holds `://`.
  - After a letter, a digit, `_`, `-`, `/` or `.`. This excludes a path
    segment, a file name, a hash and a version string.
  - Before a letter, a digit or `_`.

WHAT FAILS

  - A number that the index does not hold.
  - A retired number. The message names the number to cite.
  - A number that does not have exactly four digits.
  - An index with a malformed row, a duplicate number, or fewer live rows
    than MIN_LIVE. A short or empty index is a setup error, never a pass.

EXEMPTIONS, KEYED BY CONTENT, NEVER BY LINE NUMBER

  1. The index file. It lists the retired numbers.
  2. Each `CHANGELOG.md`. The release tool writes it from old commit subjects.
  3. This script, which holds the wrong citations of its own fixtures.
  4. The allow file `.adr-citations-allow` at the repository root. It lists
     repo-relative paths, one for each line. Each entry needs a `# why:`
     comment on the line above it. An entry that exempts no finding fails the
     guard, so the list cannot rot.
  5. The marker `adr-citations-exempt:` on the same line as the citation. A
     test that needs a retired number declares it there.

USAGE

  REPO_ROOT=<path> python3 check-adr-citations.py [--index docs/adr-index.md]
  python3 check-adr-citations.py --selftest

Exit codes: 0 clean, 1 a finding or a failed self-test, 2 usage or setup error.
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys
import tempfile

GUARD = "adr-citations"
ALLOW_FILE = ".adr-citations-allow"
EXEMPT_MARKER = "adr-citations-exempt:"
DEFAULT_INDEX = "docs/adr-index.md"
# This file holds the wrong citations of its own fixtures. The path is in the
# scanned tree only when zeroroot-ai/.github scans itself.
SELF = "actions/adr-citations/check-adr-citations.py"

# The series held 108 live records on 2026-10-05. A copy with fewer rows than
# the floor is truncated or is the wrong file.
MIN_LIVE = 100

URL = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://\S+")
CITATION = re.compile(r"(?<![A-Za-z0-9_/.-])ADR-(\d+)(?![A-Za-z0-9_])")
WIKI = re.compile(r"(?<!\[)\[\[(\d{4})\]\](?!\])")
INDEX_ROW = re.compile(r"^\| ADR-(\d{4}) \|(.*)\|\s*$")
MARKDOWN = (".md", ".mdx")


class SetupError(Exception):
    pass


def parse_index(text: str, min_live: int) -> tuple[set[str], dict[str, str]]:
    """Return (live numbers, retired number -> what to cite)."""
    live: set[str] = set()
    retired: dict[str, str] = {}
    section = ""
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.startswith("## "):
            section = line[3:].strip()
            continue
        if not line.startswith("| ADR-"):
            continue
        m = INDEX_ROW.match(line)
        if not m:
            raise SetupError(f"index line {lineno}: the row is malformed")
        number = m.group(1)
        cells = [c.strip() for c in m.group(2).split("|")]
        if number in live or number in retired:
            raise SetupError(f"index line {lineno}: ADR-{number} appears two times")
        if section == "Live" and len(cells) == 1:
            live.add(number)
        elif section == "Retired" and len(cells) == 2:
            retired[number] = cells[1]
        else:
            raise SetupError(f"index line {lineno}: the row does not fit the '{section}' table")
    if len(live) < min_live:
        raise SetupError(f"the index holds {len(live)} live rows, and the floor is {min_live}")
    return live, retired


def parse_allow(root: pathlib.Path) -> tuple[dict[str, int], list[str]]:
    """Return (path -> line number, format errors) from the allow file."""
    paths: dict[str, int] = {}
    errors: list[str] = []
    f = root / ALLOW_FILE
    if not f.is_file():
        return paths, errors
    why = False
    for lineno, raw in enumerate(f.read_text().splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            if re.match(r"^#\s*why:\s*\S", line):
                why = True
            continue
        if not why:
            errors.append(f"{ALLOW_FILE}:{lineno}: '{line}' has no '# why:' comment above it")
        paths[line] = lineno
        why = False
    return paths, errors


def citations(line: str, markdown: bool) -> list[str]:
    """Return the digit strings that the line cites."""
    spans = [m.span() for m in URL.finditer(line)]

    def in_url(pos: int) -> bool:
        return any(a <= pos < b for a, b in spans)

    found = [m.group(1) for m in CITATION.finditer(line) if not in_url(m.start())]
    if markdown:
        found += [m.group(1) for m in WIKI.finditer(line) if not in_url(m.start())]
    return found


def scan(root: pathlib.Path, index_rel: str, min_live: int = MIN_LIVE) -> tuple[list[str], int, int]:
    """Return (findings, citations read, files read)."""
    index = root / index_rel
    if not index.is_file():
        raise SetupError(f"{index_rel} does not exist. Copy docs/adr-index.md from zeroroot-ai/gibson.")
    live, retired = parse_index(index.read_text(), min_live)
    allow, findings = parse_allow(root)
    allow_used: set[str] = set()

    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=False)
    if out.returncode != 0:
        raise SetupError(f"git ls-files failed in {root}: {out.stderr.decode().strip()}")
    files = [p for p in out.stdout.decode().split("\0") if p]
    if not files:
        raise SetupError(f"{root} has no tracked file")

    read = 0
    cited = 0
    for rel in files:
        if rel in (index_rel, ALLOW_FILE, SELF) or pathlib.PurePosixPath(rel).name == "CHANGELOG.md":
            continue
        path = root / rel
        if path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        if b"\0" in data[:8192]:
            continue
        read += 1
        markdown = rel.lower().endswith(MARKDOWN)
        for lineno, line in enumerate(data.decode("utf-8", errors="replace").splitlines(), 1):
            if "ADR-" not in line and "[[" not in line:
                continue
            if EXEMPT_MARKER in line:
                continue
            for digits in citations(line, markdown):
                cited += 1
                if len(digits) != 4:
                    problem = f"ADR-{digits} does not have four digits"
                elif digits in live:
                    continue
                elif digits in retired:
                    problem = f"ADR-{digits} is retired. Cite: {retired[digits]}"
                else:
                    problem = f"ADR-{digits} is not in {index_rel}"
                if rel in allow:
                    allow_used.add(rel)
                    continue
                findings.append(f"{rel}:{lineno}: {problem}")

    for rel, lineno in allow.items():
        if rel not in allow_used:
            findings.append(f"{ALLOW_FILE}:{lineno}: '{rel}' exempts no finding. Remove the entry.")
    return findings, cited, read


def run(root: pathlib.Path, index_rel: str) -> int:
    try:
        findings, cited, read = scan(root, index_rel)
    except SetupError as e:
        print(f"{GUARD}: setup error: {e}", file=sys.stderr)
        return 2
    for f in findings:
        print(f"{GUARD}: {f}", file=sys.stderr)
    if findings:
        print(f"{GUARD}: {len(findings)} finding(s). The index is {index_rel}.", file=sys.stderr)
        return 1
    print(f"{GUARD}: OK. {cited} citation(s) in {read} file(s) name a live ADR.")
    return 0


# --- self-test ---------------------------------------------------------------

FIXTURE_INDEX = """\
# ADR index

## Live

| ADR | Rule |
|---|---|
| ADR-0003 | One code path |
| ADR-0092 | A service connects by cluster DNS |

## Retired

| ADR | What it decided | Cite this number |
|---|---|---|
| ADR-0008 | Register the service name | ADR-0092 |
| ADR-0005 | Shared Argo resources | None. No ADR holds this rule. |
"""


def _repo(files: dict[str, str], index: str | None = FIXTURE_INDEX) -> tempfile.TemporaryDirectory:
    tmp = tempfile.TemporaryDirectory()
    root = pathlib.Path(tmp.name)
    if index is not None:
        files = {DEFAULT_INDEX: index, **files}
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    for cmd in (["init", "-q"], ["add", "-A"]):
        subprocess.run(["git", "-C", str(root), *cmd], check=True, capture_output=True)
    return tmp


def selftest() -> int:
    failures: list[str] = []
    cases = 0

    def case(name: str, files: dict[str, str], want: str, index: str | None = FIXTURE_INDEX) -> None:
        """want: 'pass', 'setup', or a text that one finding must hold."""
        nonlocal cases
        cases += 1
        with _repo(files, index) as tmp:
            try:
                findings, _, _ = scan(pathlib.Path(tmp), DEFAULT_INDEX, min_live=2)
                got = "pass" if not findings else "\n".join(findings)
            except SetupError as e:
                got = f"setup: {e}"
        ok = (
            got == "pass" if want == "pass"
            else got.startswith("setup") if want == "setup"
            else want in got and not got.startswith("setup")
        )
        if not ok:
            failures.append(f"{name}: want {want!r}, got {got!r}")

    # Each fixture in this block must FAIL. A guard that passes one cannot fail.
    case("an unknown number fails", {"a.go": "// see ADR-0777\n"}, "a.go:1: ADR-0777 is not in")
    case("a retired number fails", {"a.go": "// see ADR-0008\n"}, "ADR-0008 is retired. Cite: ADR-0092")
    case("a retired number with no successor fails", {"a.sh": "# ADR-0005\n"}, "ADR-0005 is retired")
    case("a number with two digits fails", {"a.go": "// ADR-12\n"}, "ADR-12 does not have four digits")
    case("a number with five digits fails", {"a.go": "// ADR-00030\n"}, "does not have four digits")
    case("a wiki citation in Markdown fails", {"a.md": "See [[0777]].\n"}, "a.md:1: ADR-0777 is not in")
    case("a citation in parentheses fails", {"a.go": "// (ADR-0777)\n"}, "ADR-0777")
    case("a citation after a series name fails", {"a.go": "// gibson ADR-0777\n"}, "ADR-0777")
    case("two citations with a slash fail on the second", {"a.go": "// ADR-0003/0777 and ADR-0777\n"}, "ADR-0777")
    case("a citation after a URL on the same line fails",
         {"a.md": "https://example.com/x and ADR-0777\n"}, "ADR-0777")
    case("an allow entry with no why fails", {"a.go": "// ADR-0777\n", ALLOW_FILE: "a.go\n"}, "no '# why:'")
    case("an allow entry that exempts nothing fails",
         {"a.go": "// ADR-0003\n", ALLOW_FILE: "# why: history\na.go\n"}, "exempts no finding")
    case("a missing index is a setup error", {"a.go": "// ADR-0003\n"}, "setup", index=None)
    case("an index under the floor is a setup error", {"a.go": "x\n"}, "setup",
         index=FIXTURE_INDEX.replace("| ADR-0092 | A service connects by cluster DNS |\n", ""))
    case("an index with a duplicate number is a setup error", {"a.go": "x\n"}, "setup",
         index=FIXTURE_INDEX.replace("| ADR-0008 |", "| ADR-0003 |"))
    case("an index with a malformed row is a setup error", {"a.go": "x\n"}, "setup",
         index=FIXTURE_INDEX.replace("| ADR-0003 | One code path |", "| ADR-0003 | One code path"))

    # Each fixture in this block must PASS.
    case("a live number passes", {"a.go": "// ADR-0003 and (ADR-0092).\n", "b.md": "[[0003]]\n"}, "pass")
    case("a number in a URL passes", {"a.md": "https://example.com/adr/ADR-0777.md\n"}, "pass")
    case("a number in a path passes", {"a.md": "see docs/ADR-0777-old.md and x/ADR-0777\n"}, "pass")
    case("a number in a longer name passes", {"a.go": "x := MY-ADR-0777 + ADR-0777b + sha.ADR-0777\n"}, "pass")
    case("a nested list in code passes", {"a.go": "var x = [[0777]]\n", "b.json": "[[1024]]\n"}, "pass")
    case("a changelog passes", {"CHANGELOG.md": "ADR-0008\n", "sub/CHANGELOG.md": "ADR-0777\n"}, "pass")
    case("an exempt marker passes", {"a_test.go": "// ADR-0008 adr-citations-exempt: fixture\n"}, "pass")
    case("an allow entry with a why passes",
         {"old.md": "ADR-0008\n", ALLOW_FILE: "# why: a record of the old series\nold.md\n"}, "pass")
    case("a binary file passes", {"a.bin": "\0ADR-0777\n"}, "pass")

    if failures:
        for f in failures:
            print(f"{GUARD}: selftest FAILED: {f}", file=sys.stderr)
        return 1
    if cases < 25:
        print(f"{GUARD}: selftest ran {cases} cases, and the floor is 25", file=sys.stderr)
        return 1
    print(f"{GUARD}: selftest OK ({cases} cases)")
    return 0


def main(argv: list[str]) -> int:
    args = argv[1:]
    if args == ["--selftest"]:
        return selftest()
    index_rel = DEFAULT_INDEX
    if len(args) == 2 and args[0] == "--index":
        index_rel = args[1]
    elif args:
        print(__doc__, file=sys.stderr)
        return 2
    root = pathlib.Path(os.environ.get("REPO_ROOT") or os.environ.get("GITHUB_WORKSPACE") or ".").resolve()
    return run(root, index_rel)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
