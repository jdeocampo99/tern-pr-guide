#!/bin/sh
# Throwaway, local-only repos. Deliberately separate from the Luau runner (no process API).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOL="$ROOT/tools/conflicts"
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/prguide-conflicts.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
mkdir "$SANDBOX/repo"
cd "$SANDBOX/repo"
git init -q -b main
git config merge.conflictStyle diff3
python3 - <<'PY'
from pathlib import Path
Path('a.txt').write_text('before\nold\nafter\n' + 'context\n' * 12 + 'second old\nend\n')
Path('b.txt').write_text('old\n')
Path('long.txt').write_text(''.join(f'old {i}\n' for i in range(500)))
PY
git add .
git commit -qm 'Initial content'
git switch -qc topic
python3 - <<'PY'
from pathlib import Path
p=Path('a.txt'); p.write_text(p.read_text().replace('old', 'viewer'))
Path('b.txt').write_text('viewer\n')
Path('long.txt').write_text(''.join(f'viewer {i}\n' for i in range(500)))
PY
git commit -qam 'Preserve viewer changes'
git switch -q main
python3 - <<'PY'
from pathlib import Path
p=Path('a.txt'); p.write_text(p.read_text().replace('old', 'base'))
Path('b.txt').write_text('base\n')
Path('long.txt').write_text(''.join(f'base {i}\n' for i in range(500)))
PY
git commit -qam 'Update the base branch'
git switch -q topic
if git merge --no-commit main >"$SANDBOX/merge.log" 2>&1; then
 echo 'Expected a conflict' >&2; exit 1
fi
"$TOOL" list >"$SANDBOX/list.json"
python3 - "$SANDBOX/list.json" <<'PY'
import json, sys
hunks=json.load(open(sys.argv[1]))['hunks']
assert [(h['id'], h['path']) for h in hunks] == [('h1','a.txt'),('h2','a.txt'),('h3','b.txt'),('h4','long.txt')], hunks
PY
"$TOOL" show h1 >"$SANDBOX/show.json"
python3 - "$SANDBOX/show.json" <<'PY'
import json,sys
h=json.load(open(sys.argv[1]))
assert h['base']==['old'] and h['ours']==['viewer'] and h['theirs']==['base']
assert h['context']['before']==['before']
assert h['subjects']['ours']==['Preserve viewer changes']
assert h['subjects']['theirs']==['Update the base branch']
PY
"$TOOL" show h4 >"$SANDBOX/long.json"
python3 - "$SANDBOX/long.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); h=json.loads(p.read_text())
assert p.stat().st_size < 12000
for side in ['base','ours','theirs']:
 assert len(h[side])==41 and h[side][-1]=='460 more lines'
for side in ['ours','theirs']:
 assert len(h['subjects'][side])<=5 and all(len(s)<=100 for s in h['subjects'][side])
PY
"$TOOL" take h1 ours >"$SANDBOX/take.json"
"$TOOL" list >"$SANDBOX/after.json"
python3 - "$SANDBOX/after.json" <<'PY'
import json,sys
assert [h['id'] for h in json.load(open(sys.argv[1]))['hunks']]==['h2','h3','h4']
PY
printf 'combined second\n' | "$TOOL" write h2 >"$SANDBOX/write.json"
"$TOOL" take h3 both >"$SANDBOX/both.json"
set +e
"$TOOL" check >"$SANDBOX/remaining.json"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ]
"$TOOL" take h4 theirs >"$SANDBOX/theirs.json"
"$TOOL" check >"$SANDBOX/check.json"
python3 - "$SANDBOX" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
assert json.loads((p/'take.json').read_text())=={'id':'h1','taken':'ours'}
assert json.loads((p/'write.json').read_text())=={'id':'h2','lines':1}
assert json.loads((p/'remaining.json').read_text())=={'remaining':1}
assert json.loads((p/'check.json').read_text())=={'remaining':0}
assert Path('b.txt').read_text()=='viewer\nbase\n'
assert 'combined second' in Path('a.txt').read_text()
assert Path('long.txt').read_text().startswith('base 0\n')
PY
[ -z "$(git diff --name-only --diff-filter=U)" ]
set +e
"$TOOL" show missing >"$SANDBOX/unknown.json"
UNKNOWN=$?
"$TOOL" take h1 invalid >"$SANDBOX/usage.json"
USAGE=$?
set -e
[ "$UNKNOWN" -eq 1 ] && [ "$USAGE" -eq 2 ]

# A new merge of the same commits must discard the resolved journal from the first run.
# No tool command runs between abort and merge, as when the pool cleans a returned tree.
MERGE_ID=$(git rev-parse HEAD MERGE_HEAD)
git merge --abort
git clean -fd
if git merge --no-commit main >"$SANDBOX/repeat-merge.log" 2>&1; then
 echo 'Expected the repeated merge to conflict' >&2; exit 1
fi
[ "$(git rev-parse HEAD MERGE_HEAD)" = "$MERGE_ID" ]
"$TOOL" list >"$SANDBOX/repeat-list.json"
python3 - "$SANDBOX" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
assert json.loads((p/'repeat-list.json').read_text()) == json.loads((p/'list.json').read_text())
PY
"$TOOL" show h1 >"$SANDBOX/repeat-show.json"
python3 - "$SANDBOX" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
assert json.loads((p/'repeat-show.json').read_text()) == json.loads((p/'show.json').read_text())
PY
"$TOOL" take h1 ours >"$SANDBOX/repeat-take.json"
"$TOOL" list >"$SANDBOX/repeat-after.json"
python3 - "$SANDBOX/repeat-after.json" <<'PY'
import json,sys
assert [h['id'] for h in json.load(open(sys.argv[1]))['hunks']] == ['h2','h3','h4']
PY
printf 'combined second\n' | "$TOOL" write h2 >"$SANDBOX/repeat-write.json"
"$TOOL" take h3 both >"$SANDBOX/repeat-both.json"
"$TOOL" take h4 theirs >"$SANDBOX/repeat-theirs.json"
"$TOOL" check >"$SANDBOX/repeat-check.json"
python3 - "$SANDBOX/repeat-check.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1])) == {'remaining':0}
PY
[ -z "$(git diff --name-only --diff-filter=U)" ]

# The journal resets on a different merge; malformed markers and invalid JSON never pass.
git commit -qm 'Resolve the first merge'
git switch -qc next
printf '{"value": "viewer"}\n' > data.json
git add data.json
git commit -qm 'Add JSON on viewer branch'
git switch -q main
printf '{"value": "base"}\n' > data.json
git add data.json
git commit -qm 'Add JSON on base branch'
git switch -q next
if git merge --no-commit main >"$SANDBOX/merge2.log" 2>&1; then exit 1; fi
"$TOOL" list >"$SANDBOX/list2.json"
printf '{invalid}\n' | "$TOOL" write h1 >"$SANDBOX/write2.json"
set +e
"$TOOL" check >"$SANDBOX/invalid.json"
INVALID=$?
set -e
[ "$INVALID" -eq 1 ]
printf '{"value": "combined"}\n' > data.json
"$TOOL" check >"$SANDBOX/valid.json"
printf '<<<<<<< stray\n' >> data.json
set +e
"$TOOL" check >"$SANDBOX/marker.json"
MARKER=$?
set -e
[ "$MARKER" -eq 1 ]
# Default two-sided Git markers still expose their base; generated paths include lockfiles.
printf '{"value": "combined"}\n' > data.json
git add data.json
git commit -qm 'Resolve the JSON merge'
git config merge.conflictStyle merge
printf 'old\n' > plain.txt
printf '{"name":"old"}\n' > package-lock.json
printf 'old\n' > generated.txt
printf 'generated.txt linguist-generated=true\n' > .gitattributes
git add .
git commit -qm 'Add generated and plain files'
git branch fixture-base
printf 'viewer\n' > plain.txt
printf '{"name":"viewer"}\n' > package-lock.json
printf 'viewer\n' > generated.txt
git commit -qam 'Change the viewer files'
git switch -q fixture-base
printf 'base\n' > plain.txt
printf '{"name":"base"}\n' > package-lock.json
printf 'base\n' > generated.txt
git commit -qam 'Change the base files'
git switch -q next
if git merge --no-commit fixture-base >"$SANDBOX/merge3.log" 2>&1; then exit 1; fi
"$TOOL" list >"$SANDBOX/list3.json"
"$TOOL" show h3 >"$SANDBOX/plain.json"
python3 - "$SANDBOX" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
assert json.loads((p/'list3.json').read_text())['generated']==['generated.txt','package-lock.json']
h=json.loads((p/'plain.json').read_text())
assert h['path']=='plain.txt' and h['base']==['old'] and h['ours']==['viewer'] and h['theirs']==['base']
PY
"$TOOL" take h1 theirs >"$SANDBOX/generated.json"
"$TOOL" take h2 theirs >"$SANDBOX/lockfile.json"
"$TOOL" take h3 ours >"$SANDBOX/plain-take.json"
"$TOOL" check >"$SANDBOX/final-check.json"
echo 'conflicts tool assertions passed'
