#!/usr/bin/env bash
# Drive the REAL bin/fm-test-compute.sh router from the run worktree against a
# disposable local emulator of the GitHub Actions / GitLab APIs (gh-axi, glab).
#
# Oracle for every expected result comes from the change's stated contract:
#   0  = proven routed success, or local admission after an unavailable tier
#   1  = a real test/lint verdict backed by hosted receipts
#   77 = hosted outcome indeterminate (infrastructure/monitoring), never a verdict
# plus the 2026-11-04 incident: a confirmed-cancelled hosted lint queue timeout
# and an ambiguous lint dispatch must fall back instead of reporting a lint
# failure. No check here reads the router's source text.
set -uo pipefail
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKTREE=${WORKTREE:-/home/sean_/.no-mistakes/worktrees/4936102b4bcf/01M6JZR59HZNPTKGFNQHW1YSDH}
EVIDENCE=$SELF
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-compute-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT

repo="$LAB/repo"
mkdir -p "$repo/bin" "$repo/tests" "$repo/.github/workflows" "$LAB/tools" "$LAB/state"
cp "$WORKTREE/bin/fm-test-compute.sh" "$repo/bin/"
cp "$WORKTREE/.github/workflows/test-compute.gitlab.template" "$repo/.github/workflows/"
printf '#!/usr/bin/env bash\necho "local-admission: $*"\nexit "${LOCAL_RC:-0}"\n' > "$repo/bin/fm-pc02-test-offload.sh"
cat > "$repo/bin/fm-test-run.sh" <<'RUN'
#!/usr/bin/env bash
case "$*" in
  '--list-lanes') printf '%s\n' portable-parallel-1 portable-parallel-9 ;;
  '--list --lane portable-parallel-1') echo tests/sample.test.sh ;;
  '--list --lane portable-parallel-9') echo tests/derived.test.sh ;;
  *' --list') printf '%s\n' tests/sample.test.sh tests/derived.test.sh ;;
  *) : ;;
esac
RUN
chmod +x "$repo/bin/"*.sh
printf 'tests stub\n' > "$repo/tests/sample.test.sh"
printf 'tests stub\n' > "$repo/tests/derived.test.sh"
git -C "$repo" init -q -b main
git -C "$repo" add .
git -C "$repo" -c user.name=Lab -c user.email=lab@example.invalid commit -qm base
base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" update-ref refs/remotes/origin/main "$base"
git -C "$repo" remote add origin https://github.com/example/firstmate.git
printf 'change\n' > "$repo/tests/change.txt"
git -C "$repo" add .
git -C "$repo" -c user.name=Lab -c user.email=lab@example.invalid commit -qm change

cat > "$LAB/tools/gh-axi" <<'MOCK'
#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
state = pathlib.Path(os.environ['LAB_STATE'])
scenario = os.environ.get('SCENARIO', 'ok')
with open(state / 'calls.log', 'a') as f:
    f.write('gh-axi ' + ' '.join(args) + '\n')

def payload():
    return json.loads(json.loads((state / 'request.json').read_text())['inputs']['snapshot'])

if args[:2] == ['run', 'download']:
    dest = pathlib.Path(args[args.index('--dir') + 1])
    p = payload()
    for k in p['partitions']:
        d = dest / k
        d.mkdir(parents=True, exist_ok=True)
        rc = 1 if (scenario == 'real-lint-failure' and k == 'lint-1') else 0
        (d / 'result.json').write_text(json.dumps(
            dict(version=1, sha=p['sha'], partition=k, scripts=p['partitions'][k], exit=rc)))
        (d / 'run.log').write_text('hosted evidence for ' + k + '\n')
    sys.exit(0)

assert args[0] == 'api', args
rest = args[1:]
if rest and rest[0] == 'POST':
    rest = rest[1:]
path = rest[0]
jq = rest[rest.index('--jq') + 1] if '--jq' in rest else ''

if path == '/repos/example/firstmate':
    print('false\tmain'); sys.exit(0)
if path.endswith('/actions/workflows/test-compute.yml'):
    if scenario.startswith('gitlab'):
        sys.exit(1)
    print('active'); sys.exit(0)
if path.endswith('/dispatches'):
    (state / 'request.json').write_text(
        pathlib.Path(rest[rest.index('--input') + 1]).read_text())
    if scenario == 'ambiguous-dispatch':
        sys.stderr.write('Post "https://api.github.com/repos/example/firstmate/actions/workflows/'
                         'test-compute.yml/dispatches": dial tcp 140.82.113.6:443: i/o timeout\n')
        sys.exit(1)
    print('{}'); sys.exit(0)
if '/actions/workflows/test-compute.yml/runs?' in path:
    if scenario in ('accepted-undiscovered', 'ambiguous-dispatch'):
        sys.exit(0)
    print('123\tqueued\t'); sys.exit(0)
if path.endswith('/cancel'):
    (state / 'cancelled').touch(); print('{}'); sys.exit(0)
if path.endswith('/actions/runs/123'):
    if scenario == 'observation-failure':
        sys.exit(1)
    if scenario == 'lint-queue-timeout':
        print('completed\tcancelled' if (state / 'cancelled').exists() else 'queued\t')
        sys.exit(0)
    if scenario == 'real-lint-failure':
        print('completed\tfailure\t'); sys.exit(0)
    print('completed\tsuccess\t'); sys.exit(0)
sys.exit(1)
MOCK

cat > "$LAB/tools/glab" <<'MOCK'
#!/usr/bin/env python3
import io, json, os, pathlib, sys, zipfile
args = sys.argv[1:]
state = pathlib.Path(os.environ['LAB_STATE'])
scenario = os.environ.get('SCENARIO', 'ok')
with open(state / 'calls.log', 'a') as f:
    f.write('glab ' + ' '.join(args) + '\n')

if args[:2] == ['auth', 'status']:
    sys.exit(0 if scenario.startswith('gitlab') else 1)

assert args[0] == 'api', args
rest = args[1:]
while rest and rest[0] in ('--hostname', 'gitlab.com'):
    rest = rest[1:]
if rest and rest[0] == '--method':
    rest = rest[2:]
path = next(x for x in rest if x.startswith('projects/'))

if path.endswith('/pipeline'):
    q = json.loads(pathlib.Path(rest[rest.index('--input') + 1]).read_text())
    (state / 'gitlab-payload.json').write_text(q['variables'][0]['value'])
    print('{"id":456}'); sys.exit(0)
if path.endswith('/pipelines/456'):
    if scenario == 'gitlab-queue-then-status-fault':
        sys.exit(1)
    print(json.dumps(dict(status='success'))); sys.exit(0)
if '/jobs?' in path:
    if scenario == 'gitlab-malformed-jobs':
        print('this is not json'); sys.exit(0)
    print(json.dumps([dict(id=1, artifacts_file=dict(filename='x.zip'))])); sys.exit(0)
if path.endswith('/artifacts'):
    p = json.loads((state / 'gitlab-payload.json').read_text())
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        for k in p['partitions']:
            z.writestr(f'result/{k}/result.json', json.dumps(
                dict(version=1, sha=p['sha'], partition=k, scripts=p['partitions'][k], exit=0)))
            z.writestr(f'result/{k}/run.log', 'gitlab evidence ' + k + '\n')
    sys.stdout.buffer.write(buf.getvalue()); sys.exit(0)
print(json.dumps(dict(empty_repo=False, default_branch='main'))); sys.exit(0)
MOCK
chmod +x "$LAB/tools/"*

export PATH="$LAB/tools:$PATH"
export LAB_STATE="$LAB/state"
export FM_TEST_COMPUTE_QUEUE_SECS=2 FM_TEST_COMPUTE_POLL_SECS=1 FM_TEST_COMPUTE_API_SECS=5
export FM_TEST_COMPUTE_DISABLE=0 CI=true GITHUB_ACTIONS=false GITLAB_CI=false
unset GITLAB_TOKEN FM_TEST_COMPUTE_GITLAB_PROJECT

router="$repo/bin/fm-test-compute.sh"
fails=0
# drive <id> <scenario> <mode> <expected> <label> <must-contain> <must-not-contain> <local:yes|no> <gitlab:yes|no> <cancel:yes|no>
drive() {
  local id=$1 scenario=$2 mode=$3 expected=$4 label=$5 must=$6 mustnot=$7 want_local=$8 want_gitlab=$9 want_cancel=${10}
  local log="$EVIDENCE/$id.log"
  rm -f "$LAB/state/"*
  local args=()
  [ "$mode" = lint ] && args=(lint) || args=(test --changed --exclude-family real-herdr-gated --exclude-quarantined)
  ( cd "$repo" && SCENARIO="$scenario" "$router" "${args[@]}" ) > "$LAB/out" 2> "$LAB/err"
  local rc=$?
  local ok=1 checks=''
  add() { checks+="    $1"$'\n'; }
  {
    printf '# %s\n' "$id"
    printf '# what it proves: %s\n' "$label"
    printf '# product: bin/fm-test-compute.sh copied unmodified from the run worktree\n'
    printf '# emulator: local gh-axi/glab stand-ins on PATH serving synthetic GitHub Actions + GitLab API responses\n'
    printf '# command: fm-test-compute.sh %s   (SCENARIO=%s)\n' "${args[*]}" "$scenario"
    printf '## exit: %s   (expected %s)\n' "$rc" "$expected"
    printf '## stdout:\n'; sed 's/^/    /' "$LAB/out"
    printf '## stderr:\n'; sed 's/^/    /' "$LAB/err"
    printf '## hosted API calls:\n'
    if [ -s "$LAB/state/calls.log" ]; then sed 's/^/    /' "$LAB/state/calls.log"; else echo '    (none)'; fi
  } > "$log"
  if [ "$rc" = "$expected" ]; then add "PASS exit $rc == $expected"; else add "FAIL exit $rc != $expected"; ok=0; fi
  if [ -n "$must" ] && ! grep -qE -- "$must" "$LAB/out" "$LAB/err"; then
    add "FAIL missing expected diagnostic: $must"; ok=0
  elif [ -n "$must" ]; then add "PASS diagnostic present: $must"; fi
  if [ -n "$mustnot" ] && grep -qE -- "$mustnot" "$LAB/out" "$LAB/err"; then
    add "FAIL unexpected diagnostic: $mustnot"; ok=0
  elif [ -n "$mustnot" ]; then add "PASS absent: $mustnot"; fi
  if grep -q 'local-admission:' "$LAB/out"; then
    if [ "$want_local" = yes ]; then add 'PASS local admission was used: '"$(grep -o 'local-admission:.*' "$LAB/out")"
    else add 'FAIL local admission ran when it should not have'; ok=0; fi
  else
    if [ "$want_local" = no ]; then add 'PASS no local admission (hosted result stands)'
    else add 'FAIL no local admission'; ok=0; fi
  fi
  if [ -s "$LAB/state/calls.log" ] && grep -q '^glab ' "$LAB/state/calls.log"; then
    if [ "$want_gitlab" = yes ]; then add 'PASS GitLab tier was attempted'; else add 'FAIL GitLab was contacted when the GitHub result must stand'; ok=0; fi
  else
    if [ "$want_gitlab" = yes ]; then add 'FAIL GitLab tier was never attempted'; ok=0; else add 'PASS GitLab tier was not contacted'; fi
  fi
  if [ -e "$LAB/state/cancelled" ]; then
    if [ "$want_cancel" = yes ]; then add 'PASS cancellation of the owned GitHub run was confirmed'; else add 'FAIL unexpected cancellation'; ok=0; fi
  else
    if [ "$want_cancel" = yes ]; then add 'FAIL owned GitHub run was not cancelled'; ok=0; else add 'PASS no cancellation requested'; fi
  fi
  { printf '## checks:\n%s' "$checks"; printf '## result: %s\n' "$([ "$ok" = 1 ] && echo PASS || echo FAIL)"; } >> "$log"
  [ "$ok" = 1 ] || fails=$((fails + 1))
  printf '%-46s %s (exit %s)\n' "$id" "$([ "$ok" = 1 ] && echo PASS || echo FAIL)" "$rc"
}

drive 01-lint-queue-timeout-falls-back lint-queue-timeout lint 0 \
  'the 07:35Z incident: a hosted lint run queued past the bound with confirmed cancellation falls back to local lint admission, never a lint verdict' \
  'falling back to local admission' '' yes yes yes

drive 02-lint-ambiguous-dispatch-falls-back ambiguous-dispatch lint 0 \
  'the 09:40Z incident: an ambiguous lint dispatch whose run never appears within the bound falls back to local lint admission' \
  'treating as not started' '' yes yes no

drive 03-accepted-undiscovered-lint-fails-closed accepted-undiscovered lint 77 \
  'adversarial: an accepted (unambiguous) lint dispatch that stays undiscovered fails closed with 77, never duplicated downward' \
  'accepted but no run appeared' 'falling back to local admission' no no no

drive 03b-accepted-undiscovered-test-fails-closed accepted-undiscovered test 77 \
  'adversarial: an accepted (unambiguous) test dispatch that stays undiscovered fails closed with 77, never duplicated downward' \
  'accepted but no run appeared' 'falling back to local admission' no no no

drive 04-github-observation-fault-exit77 observation-failure lint 77 \
  'a GitHub monitoring fault during hosted lint reports indeterminate 77 rather than a lint failure' \
  'failing closed' 'falling back to local admission' no no yes

drive 05-lint-queue-then-gitlab-fault-exit77 gitlab-queue-then-status-fault lint 77 \
  'a hosted lint queue timeout followed by a GitLab monitoring fault reports indeterminate 77, not a lint failure' \
  'GitLab pipeline 456 status unavailable' 'falling back to local admission' no yes no

drive 06-gitlab-malformed-jobs-exit77 gitlab-malformed-jobs lint 77 \
  'a GitLab job listing that is malformed JSON reports indeterminate 77 instead of a lint failure' \
  'invalid job listing' 'falling back to local admission' no yes no

drive 07-real-lint-failure-still-exit1 real-lint-failure lint 1 \
  'hosted evidence that genuinely fails lint still returns 1 and names the failing partition; the 77 change does not mask lint verdicts' \
  'Hosted partition failed: lint-1' 'falling back to local admission' no no no

drive 08-control-hosted-success ok test 0 \
  'control: a clean hosted round trip proves success with matching receipts (the routed path is still green)' \
  'result: success' 'falling back to local admission' no no no

drive 09-control-gitlab-success gitlab-clean-success test 0 \
  'control: with GitHub unavailable, a clean GitLab pipeline proves success through returned receipts' \
  'gitlab evidence' 'falling back to local admission' no yes no

echo "harness failures: $fails"
exit $((fails > 0))
