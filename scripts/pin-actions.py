#!/usr/bin/env python3
"""pin-actions.py — pin every remote GitHub Action `uses:` to a commit SHA.

Usage: pin-actions.py <repo-dir> [--check]
  - `uses: owner/repo[/path]@<tag-or-branch>` becomes `@<sha> # <tag-or-branch>`
  - already-SHA-pinned lines are left alone
  - `uses: ./local` and `uses: docker://` are skipped
  - --check exits 1 if any unpinned reference remains (the guard)
  - a first-party raw fetch (`raw.githubusercontent.com/zeroroot-ai/...`) at
    a branch or tag is an unpinned reference too, in either mode
The tag is resolved with the GitHub API (annotated tags are dereferenced).
attic#24.

RAW FETCHES COUNT. A `uses:` pin is not the only way a workflow loads code
from this organization: reusable-coverage-gate.yml curled
`scripts/coverage-compare.sh` from `raw.githubusercontent.com/zeroroot-ai/
.github/main/`, so a caller that pinned the workflow by SHA still ran
whatever was on `main` at run time. The pin bought nothing. A first-party
raw URL must name a 40-hex commit or a `${{ github.*sha }}` expression
(`github.job_workflow_sha` is the commit the caller pinned). Only
`zeroroot-ai/*` URLs are checked here: a third-party raw fetch at a moving
ref is the same hazard, but the org still installs helm that way in three
places, and that is a separate root cause.

FIRST-PARTY REFERENCES COUNT TOO (.github#66). This used to skip
`zeroroot-ai/*` on the grounds that those were "re-pinned by
repin-github-consumers.sh". No such script has ever existed in this
repository, so nothing enforced it, and the convention held only where
somebody remembered: every caller of reusable-image-build.yml,
architectural-doc-coverage.yml and the policy guards pins a SHA, while
templates/tree-guards.yml shipped `@main` and was copied verbatim into 19
repositories. Scorecard and CodeQL each raised it in every repository that
scans one — 24 alerts, one root cause.

A first-party ref that moves is the same hazard as a third-party one: it
changes what CI runs with no reviewed diff. The trust boundary is not the
owner, it is whether the ref can move.

WHAT IS STILL NOT COVERED, and is not a settled exemption: a repository
referencing an action in ITSELF, which is how .github's reusable workflows
load their composite actions (`zeroroot-ai/.github/actions/brand-guard@main`
inside .github/workflows/brand-guard.yml). `./actions/x` cannot be used there
because a reusable workflow resolves `./` against the CALLER's checkout, and
a repository cannot pin to its own not-yet-existing commit without a two-step
merge. So those are skipped here, and the consumer's SHA pin of the workflow
does NOT protect the action it loads. Tracked in .github#65 — do not read
this skip as "self-references are safe".
"""
import json, pathlib, re, subprocess, sys

USES = re.compile(r'^(\s*(?:-\s+)?uses:\s*)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)((?:/[A-Za-z0-9_./-]+)?)@([^\s#]+)(\s*#.*)?$')
SHA = re.compile(r'^[0-9a-f]{40}$')
# A first-party raw fetch: owner, repo, then the ref segment. The ref is either
# a plain path segment or one `${{ ... }}` expression.
RAW = re.compile(r'raw\.githubusercontent\.com/(zeroroot-ai)/([A-Za-z0-9_.-]+)/(\$\{\{[^}]*\}\}|[^/\s"\'`]+)/')
# The only expressions that name a commit: github.sha, github.job_workflow_sha.
SHA_EXPR = re.compile(r'^\$\{\{\s*github\.[a-z_]*sha\s*\}\}$')


def raw_unpinned(line):
    """Every first-party raw fetch on the line whose ref can move."""
    out = []
    for m in RAW.finditer(line):
        ref = m.group(3)
        if SHA.match(ref) or SHA_EXPR.match(ref): continue
        out.append(f'{m.group(1)}/{m.group(2)}@{ref} (raw fetch)')
    return out
cache = {}

def resolve(owner_repo, ref):
    key = (owner_repo, ref)
    if key in cache: return cache[key]
    for kind in ('tags', 'heads'):
        try:
            out = subprocess.run(['gh', 'api', f'/repos/{owner_repo}/git/ref/{kind}/{ref}'], check=True, capture_output=True).stdout
            obj = json.loads(out)['object']
            if obj['type'] == 'tag':  # annotated: dereference
                tag = json.loads(subprocess.run(['gh', 'api', obj['url'].split('api.github.com')[1]], check=True, capture_output=True).stdout)
                sha = tag['object']['sha']
            else:
                sha = obj['sha']
            cache[key] = sha; return sha
        except subprocess.CalledProcessError:
            continue
    cache[key] = None; return None

def own_slug(repo):
    """The owner/name this directory IS, so a self-reference can be skipped."""
    try:
        url = subprocess.run(['git', '-C', str(repo), 'remote', 'get-url', 'origin'],
                             check=True, capture_output=True).stdout.decode().strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    m = re.search(r'[:/]([^/:]+/[^/]+?)(?:\.git)?$', url)
    return m.group(1) if m else None


def main():
    repo = pathlib.Path(sys.argv[1]); check = '--check' in sys.argv
    # Only a real repository root gets the self-reference skip. A fixture tree
    # sits INSIDE this repository, so asking git would hand it .github's own
    # slug and exempt the very reference the fixture exists to catch.
    mine = own_slug(repo) if (repo / '.github').is_dir() else None
    # A repo root: every tracked file under .github. Any other directory (a
    # fixture tree): every yaml file under it.
    files = []
    if (repo / '.github').is_dir():
        try:
            files = [f for f in subprocess.run(['git', '-C', str(repo), 'ls-files', '-z', '.github'], check=True, capture_output=True).stdout.decode().split('\0') if f]
        except subprocess.CalledProcessError:
            files = []
    if not files:
        files = [str(q.relative_to(repo)) for q in repo.rglob('*.y*ml') if 'node_modules' not in q.parts]
    unpinned = []; changed = 0
    for rel in files:
        if not re.search(r'\.ya?ml$', rel): continue
        p = repo / rel; lines = p.read_text().splitlines(keepends=True); new = []
        for ln in lines:
            # A raw fetch is reported in both modes. Nothing rewrites it: the
            # right ref is a decision (github.job_workflow_sha for a script
            # that must match the workflow), not a lookup.
            unpinned += [f'{rel}: {u}' for u in raw_unpinned(ln)]
            m = USES.match(ln)
            # A self-reference is skipped, not blessed — see the module docstring.
            if not m or SHA.match(m.group(4)) or m.group(2).startswith('.') or m.group(2) == mine:
                new.append(ln); continue
            if check:
                unpinned.append(f'{rel}: {m.group(2)}{m.group(3)}@{m.group(4)}'); new.append(ln); continue
            sha = resolve(m.group(2), m.group(4))
            if not sha:
                unpinned.append(f'{rel}: {m.group(2)}@{m.group(4)} (unresolvable)'); new.append(ln); continue
            new.append(f'{m.group(1)}{m.group(2)}{m.group(3)}@{sha} # {m.group(4)}\n'); changed += 1
        if not check and ''.join(new) != ''.join(lines):
            p.write_text(''.join(new))
    if check:
        for u in unpinned: print(f'::error::unpinned action {u}')
        print(f'pin-actions: {len(unpinned)} unpinned reference(s)' if unpinned else 'pin-actions: every action and reusable workflow is SHA-pinned')
        sys.exit(1 if unpinned else 0)
    for u in unpinned: print(f'WARN {u}', file=sys.stderr)
    print(f'pin-actions: pinned {changed} reference(s)')

if __name__ == '__main__': main()
