#!/usr/bin/env bash
# Live drive: real fm-test-run.sh + real fm-test-compute.sh on a disposable copy
# of this HEAD; only the hosted APIs (gh-axi/glab/ssh) and PC02 admission are stubbed.
set -u
WT=$1; T=$(mktemp -d "${TMPDIR:-/tmp}/fm-route-live.XXXXXX"); trap 'rm -rf "$T"' EXIT
F=$T/repo; mkdir -p $F $T/tools $T/data
git -C "$WT" archive HEAD | tar -x -C $F
cd $F; git init -q; git add -A; git -c user.name=t -c user.email=t@example.invalid commit -qm base
git update-ref refs/remotes/origin/main HEAD; git remote add origin https://github.com/example/firstmate.git
cat > bin/fm-pc02-test-offload.sh <<'L'
#!/usr/bin/env bash
printf 'PC02-ADMISSION:'; printf ' <%s>' "$@"; echo; echo "$*" >> "$TEST_COMPUTE_DATA/local-calls"
L
chmod +x bin/fm-pc02-test-offload.sh
echo '# live-drive change' >> README.md
git add -A; git -c user.name=t -c user.email=t@example.invalid commit -qm change
for m in gh-axi glab; do
  awk -v s="cat > \"\$TMP_ROOT/tools/$m\" <<'MOCK'" '$0==s{on=1;next} on&&$0=="MOCK"{exit} on' "$WT/tests/fm-test-compute.test.sh" > $T/tools/$m
done
printf '#!/usr/bin/env bash\necho off\n' > $T/tools/ssh; chmod +x $T/tools/*
export TEST_COMPUTE_DATA=$T/data PATH="$T/tools:$PATH" FM_TEST_COMPUTE_QUEUE_SECS=1 FM_TEST_COMPUTE_POLL_SECS=1 FM_TEST_COMPUTE_API_SECS=3 FM_TEST_COMPUTE_DISABLE=0 CI=true GITHUB_ACTIONS=false GITLAB_CI=false
run() { echo "===== \$ $*"; rm -f $T/data/*; "$@" > $T/out 2> $T/err; rc=$?
  echo "exit=$rc"; echo "--- stdout:"; grep -v '^evidence ' $T/out; echo "--- stderr (tail):"; tail -n 4 $T/err
  echo "--- hosted API calls:"; cat $T/data/calls 2>/dev/null | sort | uniq -c | head -20
  if [ -f $T/data/request ]; then python3 - $T/data/request <<'P'
import json,sys
p=json.loads(json.load(open(sys.argv[1]))['inputs']['snapshot'])
s=[x for v in p['partitions'].values() for x in v]
print('--- hosted dispatch: partitions=%d scripts=%d sha=%s'%(len(p['partitions']),len(s),p['sha'][:12]))
print('    herdr-gated in hosted payload:',sum('herdr' in x and 'real' in x for x in s), '| quarantined in payload:',[x for x in s if x in ('tests/fm-wake-pair-dedup.test.sh','tests/fm-backend-herdr.test.sh','tests/fm-procevent.test.sh','tests/fm-watch-triage.test.sh')])
P
  fi; echo; }
echo "HEAD under test: $(git -C "$WT" rev-parse HEAD)"
run bin/fm-test-run.sh --all --exclude-quarantined --pc02-if-idle
cp $T/data/local-calls $T/lc1
SCENARIO=gitlab-ok run bin/fm-test-run.sh --all --pc02-if-idle
SCENARIO=failure run bin/fm-test-run.sh --all --pc02-if-idle
echo "local remainder script count: $(tr ' ' '\n' < $T/lc1 | grep -c .)"
bin/fm-test-run.sh --all --exclude-quarantined --list > $T/all 2>/dev/null
bin/fm-test-run.sh --list-lanes | grep -c . | sed 's/^/lanes: /'
python3 - $T/all $T/lc1 $T/out <<'P'
import sys,re
allsel=set(open(sys.argv[1]).read().split()); local=set(open(sys.argv[2]).read().split())
print('full selection (real runner --list):',len(allsel),'| local remainder:',len(local))
P
SCENARIO=quota run bin/fm-test-run.sh --all --pc02-if-idle
SCENARIO=private run bin/fm-test-run.sh --all --pc02-if-idle
run bin/fm-test-run.sh --all --json --pc02-if-idle
