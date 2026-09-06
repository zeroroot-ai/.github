#!/usr/bin/env python3
"""pin-actions.py — pin every third-party GitHub Action `uses:` to a commit SHA.

Usage: pin-actions.py <repo-dir> [--check]
  - `uses: owner/repo[/path]@<tag-or-branch>` becomes `@<sha> # <tag-or-branch>`
  - already-SHA-pinned lines are left alone
  - `uses: ./local` and `uses: docker://` are skipped
  - zeroroot-ai/* references are skipped (re-pinned by repin-github-consumers.sh)
  - --check exits 1 if any unpinned third-party action remains (the guard)
The tag is resolved with the GitHub API (annotated tags are dereferenced).
attic#24.
"""
import json, pathlib, re, subprocess, sys

USES = re.compile(r'^(\s*(?:-\s+)?uses:\s*)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)((?:/[A-Za-z0-9_./-]+)?)@([^\s#]+)(\s*#.*)?$')
SHA = re.compile(r'^[0-9a-f]{40}$')
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

def main():
    repo = pathlib.Path(sys.argv[1]); check = '--check' in sys.argv
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
            m = USES.match(ln)
            if not m or m.group(2).startswith('zeroroot-ai/') or SHA.match(m.group(4)) or m.group(2).startswith('.'):
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
        print(f'pin-actions: {len(unpinned)} unpinned third-party action(s)' if unpinned else 'pin-actions: every third-party action is SHA-pinned')
        sys.exit(1 if unpinned else 0)
    for u in unpinned: print(f'WARN {u}', file=sys.stderr)
    print(f'pin-actions: pinned {changed} reference(s)')

if __name__ == '__main__': main()
