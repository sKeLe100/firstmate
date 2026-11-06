#!/usr/bin/env bash
# Hosted routing protocol regression: public-source bundles, exact receipts,
# failures, queue cancellation, GitLab admission, and unchanged local selection.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-compute)
fixture="$TMP_ROOT/repo"
mkdir -p "$fixture/bin" "$fixture/tests" "$fixture/.github/workflows" "$TMP_ROOT/tools" "$TMP_ROOT/data"
cp "$ROOT/bin/fm-test-compute.sh" "$ROOT/bin/fm-pc02-personal-use.sh" "$fixture/bin/"
cp "$ROOT/.github/workflows/test-compute.gitlab.template" "$fixture/.github/workflows/"
cat > "$fixture/bin/fm-test-run.sh" <<'RUN'
#!/usr/bin/env bash
case "$*" in
  '--list-lanes')
    [ "${LANES_RC:-0}" = 0 ] || exit "$LANES_RC"
    printf '%s\n' portable-parallel-1 portable-parallel-2 portable-parallel-9 portable-serial portable-serial-1of2 portable-serial-2of2 real-herdr-gated
    ;;
  '--changed --exclude-family real-herdr-gated --list'|'--changed --exclude-family real-herdr-gated --exclude-quarantined --list')
    [ "${SELECTION_RC:-0}" = 0 ] || exit "$SELECTION_RC"
    if [ "${ONLY_NON_HOSTED:-0}" = 1 ]; then
      printf '%s\n' tests/fm-devin-harness.test.sh tests/fm-calm-pi-extension.test.sh tests/fm-captain-hold-lifecycle.test.sh
    else
      printf '%s\n' tests/sample.test.sh tests/derived.test.sh
      if [ "${NON_HOSTED:-0}" = 1 ]; then
        printf '%s\n' tests/fm-devin-harness.test.sh tests/fm-calm-pi-extension.test.sh tests/fm-captain-hold-lifecycle.test.sh
      fi
    fi
    ;;
  '--list --lane portable-parallel-1')
    echo tests/sample.test.sh
    if [ "${NON_HOSTED:-0}" = 1 ]; then
      printf '%s\n' tests/fm-devin-harness.test.sh tests/fm-calm-pi-extension.test.sh tests/fm-captain-hold-lifecycle.test.sh
    fi
    ;;
  '--list --lane portable-parallel-9') echo tests/derived.test.sh ;;
  '--list --lane '*) : ;;
  *) printf 'ran:'; printf ' <%s>' "$@"; echo; exit "${SUITE_RC:-0}" ;;
esac
RUN
cat > "$fixture/bin/fm-pc02-test-offload.sh" <<'LOCAL'
#!/usr/bin/env bash
printf 'local:'; printf ' <%s>' "$@"; echo
exit "${LOCAL_RC:-0}"
LOCAL
cat > "$fixture/bin/fm-lint.sh" <<'LINT'
#!/usr/bin/env bash
if [ "$*" = --partition-count ]; then printf '%s\n' "${LINT_PARTITION_COUNT-4}"; exit 0; fi
if [ -n "${LINT_TRACE:-}" ]; then
  printf 'start %s\n' "$*" >> "$LINT_TRACE"
  sleep "${LINT_SLEEP_SECS:-0}"
  printf 'end %s\n' "$*" >> "$LINT_TRACE"
fi
printf 'lint:'; printf ' <%s>' "$@"; echo
if [ -n "${LINT_FAIL_PARTITION:-}" ] && [ "$*" = "--partition ${LINT_FAIL_PARTITION}" ]; then
  exit "${LINT_FAIL_RC:-1}"
fi
exit "${SUITE_RC:-0}"
LINT
chmod +x "$fixture/bin/"*.sh
git -C "$fixture" init -q
git -C "$fixture" add .
git -C "$fixture" -c user.name=Test -c user.email=test@example.invalid commit -qm base
base=$(git -C "$fixture" rev-parse HEAD)
git -C "$fixture" update-ref refs/remotes/origin/main "$base"
git -C "$fixture" remote add origin https://github.com/example/firstmate.git
printf 'sample\n' > "$fixture/tests/sample.test.sh"
git -C "$fixture" add .
git -C "$fixture" -c user.name=Test -c user.email=test@example.invalid commit -qm change
sha=$(git -C "$fixture" rev-parse HEAD)
export TEST_COMPUTE_DATA="$TMP_ROOT/data"
cat > "$TMP_ROOT/tools/gh-axi" <<'MOCK'
#!/usr/bin/env python3
import json,os,pathlib,subprocess,sys
args=sys.argv[1:]; w=pathlib.Path(os.environ['TEST_COMPUTE_DATA']); scenario=os.environ.get('SCENARIO','success')
with open(w/'calls','a') as f: f.write('github '+ ' '.join(args[:3])+'\n')
def jq(value):
    print(subprocess.run(['jq','-r',a[a.index('--jq')+1]],input=json.dumps(value),text=True,capture_output=True,check=True).stdout,end='')
    sys.exit(0)
def request(): return json.load(open(w/'request'))
def payload(): return json.loads(request()['inputs']['snapshot'])
def dispatched():
    p=payload(); keys=json.loads(request()['inputs']['partitions'])
    if not isinstance(keys,list) or keys!=list(p['partitions']):
        print('dispatch partitions do not match plan',file=sys.stderr); sys.exit(1)
    return keys
def receipt(k):
    p=payload()
    scripts=['tests/other.test.sh'] if scenario=='wrong-scripts' else p['partitions'][k]
    return dict(version=1,sha='f'*40 if scenario=='wrong-head' else p['sha'],partition=k,scripts=scripts,exit=1 if scenario=='failure' and k=='portable-parallel-1' else 0)
if args[:2]==['run','download']:
    if scenario=='download-failure': sys.exit(1)
    out=pathlib.Path(args[args.index('--dir')+1]); keys=dispatched(); p=payload()
    for k in keys:
        if scenario=='missing' and k=='portable-parallel-1': continue
        d=out/k; d.mkdir(parents=True); (d/'result.json').write_text(json.dumps(receipt(k))); (d/'run.log').write_text('evidence '+k+'\n')
    sys.exit(0)
assert args[0]=='api'
a=args[1:]; method=a.pop(0) if a[0] in ('POST','GET') else 'GET'; path=a[0]
if path.endswith('/cancel'):
    if scenario in ('cancel-failure','github-timeout-cancel-failure'): sys.exit(1)
    (w/('cancelled-124' if '/runs/124/' in path else 'cancelled')).touch(); sys.exit(0)
if '/actions/runners?' in path:
    if 'RUNNERS' not in os.environ: sys.exit(1)
    rows=[r.split(':') for r in os.environ['RUNNERS'].split()]
    jq(dict(runners=[dict(status=state,busy=busy=='busy',labels=[dict(name='self-hosted'),dict(name=label)]) for label,state,busy in rows]))
if '/actions/runs?status=queued' in path:
    if 'QUEUED_RUNS' not in os.environ: sys.exit(1)
    jq(dict(total_count=int(os.environ['QUEUED_RUNS'])))
if '/jobs?' in path:
    if scenario=='jobs-failure': sys.exit(1)
    if scenario=='admitted-queued':
        if (w/'jobs-read').exists(): sys.exit(1)
        (w/'jobs-read').touch()
    # A queued job carries started_at though it never ran; only a runner admits it.
    queued=dict(status='queued',runner_name='',started_at='2026-11-04T17:00:22Z')
    jq(dict(jobs=[queued,dict(status='in_progress',runner_name='GitHub Actions 1')] if scenario=='admitted-queued' else [queued,queued]))
if path.endswith('/dispatches'):
    if scenario=='dispatch-ambiguous': sys.exit(1)
    if scenario=='dispatch-ambiguous-found':
        (w/'request').write_text(pathlib.Path(a[a.index('--input')+1]).read_text()); sys.exit(1)
    if scenario=='quota': print('error: HTTP 403 billing unavailable'); sys.exit(1)
    body=pathlib.Path(a[a.index('--input')+1]).read_text(); (w/'request').write_text(body)
    with open(w/'requests','a') as f: f.write(body+'\n')
    sys.exit(0)
if '/workflows/test-compute.yml/runs?' in path:
    if scenario=='discovery-failure': sys.exit(1)
    if scenario=='invalid-run-id': print('not-an-id\tqueued\t'); sys.exit(0)
    if scenario in ('undiscovered','dispatch-ambiguous'): sys.exit(0)
    print(('124' if 'runner' in request()['inputs'] else '123')+'\tqueued\t'); sys.exit(0)
if path.endswith('/actions/runs/124'):
    if scenario=='self-hosted-queued': print('completed\tcancelled' if (w/'cancelled-124').exists() else 'queued\t')
    else: print('completed\tsuccess')
    sys.exit(0)
if path.endswith('/actions/runs/123'):
    if scenario=='admitted-queued':
        reads=w/'reads'; n=int(reads.read_text()) if reads.exists() else 0; reads.write_text(str(n+1))
        print('queued\t' if n<3 else 'completed\tsuccess'); sys.exit(0)
    if scenario=='observation-failure': sys.exit(1)
    if scenario.startswith('github-race-'):
        state='completed' if (w/'cancelled').exists() else 'queued'
        conclusion=scenario.removeprefix('github-race-') if state=='completed' else ''
        print(state+'\t'+conclusion); sys.exit(0)
    if scenario in ('github-timeout','github-timeout-cancel-failure') and any('.status' in arg for arg in args):
        print('completed\tcancelled' if (w/'cancelled').exists() else 'running\t')
        sys.exit(0)
    if scenario in ('queued','cancel-failure','gitlab-queue-status-failure','self-hosted-queued','jobs-failure') and any('.status' in arg for arg in args):
        print('queued\t' if scenario=='cancel-failure' or not (w/'cancelled').exists() else 'completed\tcancelled')
        sys.exit(0)
    if scenario=='github-canceled-green': print('completed\tcancelled'); sys.exit(0)
    if scenario=='queued' and not (w/'cancelled').exists(): print('queued\t')
    else: print('completed\t'+('failure' if scenario=='failure' else 'success'))
    sys.exit(0)
if path.endswith('/workflows/test-compute.yml'):
    if scenario=='github-unavailable' or (scenario.startswith('gitlab-') and scenario!='gitlab-queue-status-failure'): sys.exit(1)
    print('active'); sys.exit(0)
if path=='/repos/example/firstmate': print(('true' if scenario=='private' else 'false')+'\tmain'); sys.exit(0)
sys.exit(1)
MOCK
cat > "$TMP_ROOT/tools/glab" <<'MOCK'
#!/usr/bin/env python3
import json,os,pathlib,sys,zipfile,io
args=sys.argv[1:]; w=pathlib.Path(os.environ['TEST_COMPUTE_DATA']); scenario=os.environ.get('SCENARIO','success')
with open(w/'calls','a') as f: f.write('gitlab '+' '.join(args[:4])+'\n')
if args[:2]==['auth','status']: sys.exit(0 if scenario.startswith('gitlab-') else 1)
assert args[0]=='api'
path=next(x for x in args if x.startswith('projects/'))
if path.endswith('/repository/commits'):
    if scenario=='gitlab-bootstrap-failure': sys.exit(1)
    pathlib.Path(w/'bootstrap.json').write_text(pathlib.Path(args[args.index('--input')+1]).read_text())
    (w/'bootstrapped').touch(); print('{}'); sys.exit(0)
if path.endswith('/pipeline'):
    if scenario=='gitlab-forbidden': print(json.dumps(dict(message=dict(base=['Insufficient permissions to set pipeline variables'])))); print('glab: map[message:map[base:[Insufficient permissions to set pipeline variables]]]',file=sys.stderr); sys.exit(1)
    if scenario=='gitlab-pipeline-ambiguous': sys.exit(1)
    q=json.load(open(args[args.index('--input')+1])); p=json.loads(q['variables'][0]['value'])
    (w/'gitlab-payload').write_text(json.dumps(p))
    print('{"id":"not-an-id"}' if scenario=='gitlab-invalid-id' else '{"id":456}'); sys.exit(0)
if path.endswith('/pipelines/456/cancel'):
    if scenario=='gitlab-queue-cancel-failure': sys.exit(1)
    (w/'cancelled').touch(); print('{}'); sys.exit(0)
if path.endswith('/pipelines/456'):
    if scenario in ('gitlab-status-failure','gitlab-queue-status-failure'): sys.exit(1)
    if scenario=='gitlab-quota': status='failed'
    elif scenario in ('gitlab-queued','gitlab-queue-cancel-failure'): status='canceled' if (w/'cancelled').exists() else 'pending'
    elif scenario=='gitlab-timeout': status='canceled' if (w/'cancelled').exists() else 'running'
    elif scenario=='gitlab-canceled-green': status='canceled'
    elif scenario in ('gitlab-incomplete','gitlab-failure'): status='failed'
    elif scenario.startswith('gitlab-race-'):
        status=scenario.removeprefix('gitlab-race-') if (w/'cancelled').exists() else 'pending'
    else: status='success'
    print(json.dumps(dict(status=status))); sys.exit(0)
if path.endswith('/pipelines/456/jobs?per_page=100'):
    if scenario=='gitlab-jobs-failure': sys.exit(1)
    if scenario=='gitlab-malformed-jobs': print('not json'); sys.exit(0)
    if scenario=='gitlab-bad-jobs': print('{"id":1}'); sys.exit(0)
    if scenario=='gitlab-quota': print(json.dumps([dict(id=1,name='compute',failure_reason='ci_quota_exceeded',started_at=None)]))
    else: print(json.dumps([dict(id=1,artifacts_file={'filename':'x.zip'})]))
    sys.exit(0)
if path.endswith('/artifacts'):
    if scenario=='gitlab-artifact-failure': sys.exit(1)
    if scenario=='gitlab-bad-artifact': sys.stdout.buffer.write(b'not a zip'); sys.exit(0)
    p=json.load(open(w/'gitlab-payload')); b=io.BytesIO()
    with zipfile.ZipFile(b,'w') as z:
        for k in p['partitions']:
            if scenario=='gitlab-incomplete' and k=='portable-parallel-1': continue
            rc=1 if scenario=='gitlab-failure' and k=='portable-parallel-1' else 0
            result=dict(version=1,sha=p['sha'],partition=k,scripts=p['partitions'][k],exit=rc)
            z.writestr(f'result/{k}/result.json',json.dumps(result)); z.writestr(f'result/{k}/run.log','GitLab evidence\n')
    sys.stdout.buffer.write(b.getvalue()); sys.exit(0)
print(json.dumps(dict(empty_repo=scenario in ('gitlab-bootstrap','gitlab-bootstrap-failure'),default_branch='main')))
MOCK
cat > "$TMP_ROOT/tools/ssh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${PC02_SWITCH:-off}"
exit "${PC02_SSH_RC:-0}"
MOCK
chmod +x "$TMP_ROOT/tools/"*
export PATH="$TMP_ROOT/tools:$PATH" FM_TEST_COMPUTE_QUEUE_SECS=1 FM_TEST_COMPUTE_POLL_SECS=1 FM_TEST_COMPUTE_API_SECS=3
export FM_TEST_COMPUTE_DISABLE=0 CI=true GITHUB_ACTIONS=false GITLAB_CI=false
ruby -ryaml - "$ROOT/.no-mistakes.yaml" <<'YAML'
config = YAML.load_file(ARGV.fetch(0))
abort 'configured lint must route canonical partitions before the Pi typecheck' unless
  config.dig('commands', 'lint') == 'bin/fm-test-compute.sh lint && bash tests/fm-pi-primary-types.test.sh'
abort 'pinned Test baseline changed' unless
  config.dig('commands', 'test') == 'bin/fm-test-run.sh --changed --exclude-family real-herdr-gated --exclude-quarantined --pc02-if-idle'
YAML
pass 'trusted gate configuration routes lint and preserves the pinned Test baseline'
router="$fixture/bin/fm-test-compute.sh"
run_route() {
  rm -f "$TMP_ROOT/data/"*
  set +e
  scenario=$1
  route_kind=${2:-test}
  if [ "$route_kind" = lint ]; then
    output=$(SCENARIO="$scenario" "$router" lint 2>&1)
  else
    output=$(SCENARIO="$scenario" "$router" test --changed --exclude-family real-herdr-gated --exclude-quarantined 2>&1)
  fi
  result=$?
  set -e
}
# Asserts the runner of each GitHub dispatch, in order, and a fresh request id each.
assert_dispatches() {
  python3 - "$TMP_ROOT/data/requests" "$@" <<'PY' || fail "dispatches were not: $*"
import json,sys
rows=[json.loads(line)['inputs'] for line in open(sys.argv[1])]
got=[row.get('runner','hosted') for row in rows]
assert got==sys.argv[2:], got
assert len({row['request_id'] for row in rows})==len(rows), 'a dispatch reused a request id'
PY
}
run_route success
expect_code 0 "$result" "$output"
assert_contains "$output" 'result: success' 'receipts must prove success'
assert_contains "$output" "$sha" 'receipt must identify exact head'
[ ! -e "$TMP_ROOT/data/gitlab-payload" ] || fail 'GitLab ran after GitHub success'
python3 - "$TMP_ROOT/data/request" <<'PY'
import json,sys
payload=json.loads(json.load(open(sys.argv[1]))['inputs']['snapshot'])
assert payload['partitions']=={'portable-parallel-1':['tests/sample.test.sh'],'portable-parallel-9':['tests/derived.test.sh']}, payload['partitions']
assert not any(k.startswith('lint-') for k in payload['partitions']), 'Test dispatched lint partitions'
PY
assert_dispatches hosted
pass 'GitHub result receipts cover only the non-empty Test partitions'

rm -f "$TMP_ROOT/data/"*
set +e
output=$(LANES_RC=1 SCENARIO=success "$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 0 "$result" "$output"
assert_contains "$output" 'local:' 'lane listing failure should fall back'
[ ! -e "$TMP_ROOT/data/request" ] || fail 'lane listing failure dispatched hosted work'
pass 'lane listing failure falls back before dispatch'

rm -f "$TMP_ROOT/data/"*
set +e
output=$(SELECTION_RC=1 SCENARIO=success "$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 0 "$result" "$output"
assert_contains "$output" 'test selection cannot be listed; falling back to local admission' 'selection listing failure did not name its fallback reason'
assert_contains "$output" 'local: <--changed> <--exclude-family> <real-herdr-gated>' 'selection listing failure did not reach local admission'
[ ! -e "$TMP_ROOT/data/calls" ] || fail 'selection listing failure contacted hosted services'
pass 'selection listing failure falls back before dispatch'

rm -f "$TMP_ROOT/data/"*
set +e
output=$(ONLY_NON_HOSTED=1 SCENARIO=success "$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 0 "$result" "$output"
assert_contains "$output" 'local: <--changed> <--exclude-family> <real-herdr-gated>' 'a selection with no hosted partitions should run locally'
[ ! -e "$TMP_ROOT/data/request" ] || fail 'empty hosted subset dispatched hosted work'
pass 'a selection with no hosted-capable partitions runs locally'

rm -f "$TMP_ROOT/data/"*
set +e
output=$(NON_HOSTED=1 SCENARIO=success "$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 0 "$result" "$output"
assert_contains "$output" 'result: success' 'hosted receipts plus local-only scripts must prove success'
for non_hosted in tests/fm-devin-harness.test.sh tests/fm-calm-pi-extension.test.sh tests/fm-captain-hold-lifecycle.test.sh; do
  assert_contains "$output" "<$non_hosted>" "non-hosted script $non_hosted did not use local admission"
done
python3 - "$TMP_ROOT/data/request" <<'PY'
import json,sys
payload=json.loads(json.load(open(sys.argv[1]))['inputs']['snapshot'])
scripts=[s for v in payload['partitions'].values() for s in v]
for script in ('tests/fm-devin-harness.test.sh','tests/fm-calm-pi-extension.test.sh','tests/fm-captain-hold-lifecycle.test.sh'):
    assert script not in scripts, 'non-hosted script entered hosted dispatch: '+script
assert 'tests/sample.test.sh' in scripts, 'hosted-capable script was withheld from hosted dispatch'
PY
pass 'non-hosted scripts stay on local admission while the hosted subset keeps its tier order'

rm -f "$TMP_ROOT/data/"*
set +e
output=$(NON_HOSTED=1 SCENARIO=failure "$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 1 "$result" "$output"
[[ "$output" != *'local:'* ]] || fail 'local-only scripts ran after a hosted failure'
pass 'a hosted failure is never masked by the local-only subset'

rm -f "$TMP_ROOT/data/"*
set +e
output=$(NON_HOSTED=1 LOCAL_RC=9 SCENARIO=success "$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 9 "$result" "$output"
[[ "$output" != *'result: success'* ]] || fail 'local-only failure was reported as routed success'
assert_contains "$output" '<tests/fm-captain-hold-lifecycle.test.sh>' 'local-only script did not run'
pass 'a local-only script failure fails the whole routed run'

rm -f "$TMP_ROOT/data/"*
set +e
output=$(NON_HOSTED=1 SCENARIO=gitlab-success "$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 0 "$result" "$output"
assert_contains "$output" 'GitLab evidence' 'GitLab evidence must return to Test'
assert_contains "$output" '<tests/fm-calm-pi-extension.test.sh>' 'non-hosted script did not finish on local admission after GitLab'
python3 - "$TMP_ROOT/data/gitlab-payload" <<'PY'
import json,sys
payload=json.load(open(sys.argv[1]))
scripts=[s for v in payload['partitions'].values() for s in v]
for script in ('tests/fm-devin-harness.test.sh','tests/fm-calm-pi-extension.test.sh','tests/fm-captain-hold-lifecycle.test.sh'):
    assert script not in scripts, 'non-hosted script entered GitLab dispatch: '+script
assert 'tests/sample.test.sh' in scripts, 'hosted-capable script was withheld from GitLab dispatch'
PY
pass 'GitLab carries only hosted-capable scripts and local admission completes the selection'

run_route success lint
expect_code 0 "$result" "$output"
assert_contains "$output" 'result: success' 'hosted lint receipts must prove success'
python3 - "$TMP_ROOT/data/request" <<'PY'
import json,sys
request=json.load(open(sys.argv[1]))
payload=json.loads(request['inputs']['snapshot'])
assert payload['kind']=='lint' and set(payload['partitions'])=={f'lint-{n}' for n in range(1,5)}
assert all(not scripts for scripts in payload['partitions'].values())
PY
pass 'Lint mode runs every canonical lint partition on hosted compute'

for scenario in failure wrong-head wrong-scripts; do
  run_route "$scenario"
  expect_code 1 "$result" "$scenario must fail closed: $output"
  [[ "$output" != *'local:'* ]] || fail "$scenario fell back locally"
  [ ! -e "$TMP_ROOT/data/gitlab-payload" ] || fail "$scenario fell through to GitLab"
  pass "$scenario cannot become a green fallback"
done
run_route missing
expect_code 77 "$result" "$output"
[[ "$output" != *'local:'* ]] || fail 'missing receipts fell back locally'
assert_contains "$output" 'missing hosted partition receipts:' 'missing GitHub receipts did not name the missing partitions'
for scenario in download-failure discovery-failure observation-failure invalid-run-id cancel-failure; do
  run_route "$scenario"
  expect_code 77 "$result" "$scenario must be indeterminate, not a test verdict: $output"
  [[ "$output" != *'local:'* ]] || fail "$scenario fell back locally"
  assert_contains "$output" 'failing closed' "$scenario did not name its fail-closed reason"
  [ ! -e "$TMP_ROOT/data/gitlab-payload" ] || fail "$scenario fell through to GitLab"
  pass "$scenario names its fail-closed reason"
done
for kind in test lint; do
  run_route undiscovered "$kind"
  expect_code 77 "$result" "an accepted but undiscovered $kind dispatch must be indeterminate: $output"
  [[ "$output" != *'local:'* ]] || fail 'an accepted but undiscovered dispatch fell back locally'
  assert_contains "$output" 'GitHub dispatch was accepted but no run appeared' 'an accepted but undiscovered dispatch did not name its fail-closed reason'
  [ ! -e "$TMP_ROOT/data/gitlab-payload" ] || fail 'an accepted but undiscovered dispatch reached GitLab'
  pass "an accepted but undiscovered $kind dispatch fails closed instead of duplicating"
done
for kind in test lint; do
  run_route dispatch-ambiguous "$kind"
  expect_code 0 "$result" "dispatch-ambiguous $kind: a run that never appeared must fall back: $output"
  assert_contains "$output" 'treating as not started' "dispatch-ambiguous $kind did not name why it fell back"
  assert_contains "$output" 'local:' "dispatch-ambiguous $kind did not reach local admission"
  [ ! -e "$TMP_ROOT/data/gitlab-payload" ] || fail "dispatch-ambiguous $kind: GitLab tier was skipped incorrectly"
  pass "an ambiguous $kind dispatch with no run after the bound falls back"
done
run_route dispatch-ambiguous-found
expect_code 0 "$result" "$output"
[[ "$output" != *'local:'* ]] || fail 'an ambiguous dispatch whose run appeared fell back locally'
assert_contains "$output" 'result: success' 'an ambiguous dispatch whose run appeared must be monitored'
pass 'an ambiguous dispatch whose run appears is monitored, not duplicated'
run_route quota
expect_code 0 "$result" "$output"
assert_contains "$output" 'local:' 'definitive quota rejection should fall back'
pass 'definitive GitHub admission rejection tries the next tier'
run_route github-unavailable
expect_code 0 "$result" "$output"
assert_contains "$output" 'local: <--changed> <--exclude-family> <real-herdr-gated> <--exclude-quarantined>' 'baseline arguments must survive fallback'
pass 'GitHub unavailable and unauthenticated GitLab reach existing PC02 admission'
run_route github-unavailable lint
expect_code 0 "$result" "$output"
assert_contains "$output" 'local: <--lint-partitions>' 'unavailable hosted lint did not reach PC02 admission'
pass 'unavailable hosted lint reaches the existing PC02/PC01 fallback'
run_route queued
expect_code 0 "$result" "$output"
[ -e "$TMP_ROOT/data/cancelled" ] || fail 'queue fallback did not cancel owned GitHub run'
assert_contains "$output" 'local:' 'cancelled queue should fall back'
pass 'queue timeout requires confirmed cancellation before fallback'

RUNNERS='fm-parallel:online:idle fm-pc02:online:idle' QUEUED_RUNS=2 run_route success
expect_code 0 "$result" "$output"
assert_contains "$output" 'routing to idle self-hosted label fm-pc02' 'queued runs did not route to the preferred label'
assert_contains "$output" 'result: success' 'the self-hosted run must prove success with receipts'
assert_dispatches fm-pc02
[ ! -e "$TMP_ROOT/data/cancelled" ] || fail 'routing before dispatch cancelled a hosted run'
pass 'existing queued runs route the only dispatch to fm-pc02'
for pc02 in fm-pc02:online:busy fm-pc02:offline:idle; do
  RUNNERS="$pc02 fm-parallel:online:idle" QUEUED_RUNS=1 run_route success
  expect_code 0 "$result" "$output"
  assert_dispatches hosted
  pass "$pc02 keeps the hosted dispatch and an idle fm-parallel runner is never chosen, so PC01 stays behind heavy admission"
done
RUNNERS='fm-pc02:online:idle' QUEUED_RUNS=2 PC02_SWITCH=on run_route success
expect_code 0 "$result" "$output"
assert_dispatches hosted
pass 'the PC02 personal-use switch keeps queued-run routing off PC02'
RUNNERS='fm-pc02:online:idle' QUEUED_RUNS=2 PC02_SSH_RC=255 run_route success
expect_code 0 "$result" "$output"
assert_dispatches hosted
pass 'an unreadable PC02 personal-use switch counts as in use'
RUNNERS='fm-pc02:online:idle' QUEUED_RUNS=0 run_route success
assert_dispatches hosted
pass 'an empty repository queue keeps the hosted dispatch'

for kind in test lint; do
  RUNNERS='fm-pc02:online:idle' run_route queued "$kind"
  expect_code 0 "$result" "$output"
  [ -e "$TMP_ROOT/data/cancelled" ] || fail 'saturated hosted run was not cancelled'
  assert_dispatches hosted fm-pc02
  python3 - "$TMP_ROOT/data/calls" <<'PY' || fail 'self-hosted dispatch did not follow the confirmed cancellation'
import sys
calls=open(sys.argv[1]).read().splitlines()
order=[i for i,c in enumerate(calls) if c.endswith('/dispatches') or c.endswith('/cancel')]
assert [calls[i].rsplit('/',1)[1] for i in order]==['dispatches','cancel','dispatches'], calls
PY
  assert_contains "$output" 'hosted runners saturated; routing to idle self-hosted label fm-pc02' 'reroute did not name its reason'
  assert_contains "$output" 'result: success' 'the rerouted run must prove success with receipts'
  [[ "$output" != *'local:'* ]] || fail 'a rerouted run also ran locally'
  [[ "$(cat "$TMP_ROOT/data/calls")" != *'gitlab '* ]] || fail 'a rerouted run also reached GitLab'
  pass "a fully queued hosted $kind run reroutes after confirmed cancellation with a fresh request id"
done

RUNNERS='fm-pc02:online:busy fm-parallel:online:busy' run_route queued
expect_code 0 "$result" "$output"
assert_dispatches hosted
assert_contains "$output" 'GitHub unavailable; trying GitLab' 'busy self-hosted runners skipped the GitLab tier'
assert_contains "$output" 'local:' 'busy self-hosted runners did not reach local admission'
pass 'busy self-hosted runners keep the existing fallback order'

RUNNERS='fm-pc02:online:idle fm-parallel:online:idle' PC02_SWITCH=on run_route queued
expect_code 0 "$result" "$output"
assert_dispatches hosted
assert_contains "$output" 'GitHub unavailable; trying GitLab' 'personal use skipped the GitLab tier'
assert_contains "$output" 'local:' 'personal use did not reach local admission'
pass 'the PC02 personal-use switch sends a saturated run down the existing fallback order'

RUNNERS='fm-pc02:online:idle' run_route self-hosted-queued
expect_code 0 "$result" "$output"
assert_dispatches hosted fm-pc02
[ -e "$TMP_ROOT/data/cancelled-124" ] || fail 'a self-hosted run that could not start was not cancelled'
assert_contains "$output" 'local:' 'a self-hosted run that could not start did not fall back'
pass 'a self-hosted run that never gets a runner falls through once'

RUNNERS='fm-pc02:online:idle' run_route cancel-failure
expect_code 77 "$result" "$output"
assert_dispatches hosted
[[ "$output" != *'local:'* ]] || fail 'an unconfirmed cancellation fell back locally'
pass 'an unconfirmed cancellation stays indeterminate and never reroutes'

RUNNERS='fm-pc02:online:idle' run_route jobs-failure
expect_code 77 "$result" "$output"
assert_contains "$output" 'GitHub job observation failed for run 123; failing closed' 'a job observation fault did not name its reason'
assert_dispatches hosted
pass 'a job observation fault at the queue bound stays indeterminate'

RUNNERS='fm-pc02:online:idle' run_route admitted-queued
expect_code 0 "$result" "$output"
assert_contains "$output" 'result: success' 'an admitted run did not finish on its own receipts'
assert_contains "$(cat "$TMP_ROOT/data/calls")" '/jobs?per_page=100' 'the queue bound did not consult job state'
assert_dispatches hosted
[ ! -e "$TMP_ROOT/data/cancelled" ] || fail 'a run with an admitted job was cancelled for queueing'
pass 'a run whose status reads queued while a job holds a runner is monitored, not cancelled, and admission is read once'

RUNNERS='fm-pc02:online:idle' run_route dispatch-ambiguous
expect_code 0 "$result" "$output"
[ "$(grep -c '/dispatches$' "$TMP_ROOT/data/calls")" = 1 ] || fail 'a non-saturation fallback dispatched to self-hosted'
pass 'only a saturation signal reroutes to self-hosted'
run_route gitlab-queue-status-failure lint
expect_code 77 "$result" "$output"
[ -e "$TMP_ROOT/data/cancelled" ] || fail 'queue timeout did not cancel the owned GitHub run'
assert_contains "$output" 'GitLab pipeline 456 status unavailable; failing closed' 'a GitLab status failure did not name its fail-closed reason'
[[ "$output" != *'local:'* ]] || fail 'a GitLab status failure fell back locally and could report a lint verdict'
pass 'a hosted lint queue timeout followed by a GitLab monitoring fault is indeterminate, not a lint failure'
rm -f "$TMP_ROOT/data/"*
set +e
output=$(FM_TEST_COMPUTE_RUN_SECS=1 SCENARIO=github-timeout "$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 77 "$result" "$output"
assert_contains "$output" 'GitHub run 123 exceeded 1s; failing closed' 'GitHub execution timeout did not name its fail-closed reason'
[[ "$output" != *'local:'* ]] || fail 'GitHub execution timeout fell back locally'
pass 'a GitHub execution timeout fails closed with a diagnostic'
rm -f "$TMP_ROOT/data/"*
set +e
output=$(FM_TEST_COMPUTE_RUN_SECS=1 SCENARIO=github-timeout-cancel-failure "$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 77 "$result" "$output"
assert_contains "$output" 'GitHub run 123 exceeded 1s and cancellation was not confirmed; failing closed' 'unconfirmed GitHub cancellation did not name its fail-closed reason'
[[ "$output" != *'local:'* ]] || fail 'unconfirmed GitHub cancellation fell back locally'
pass 'an unconfirmed GitHub cancellation after timeout fails closed with a diagnostic'
run_route gitlab-queued
expect_code 0 "$result" "$output"
[ -e "$TMP_ROOT/data/cancelled" ] || fail 'GitLab queue fallback did not cancel the owned pipeline'
assert_contains "$output" 'local:' 'cancelled GitLab queue should fall back'
pass 'GitLab queue timeout requires confirmed cancellation before fallback'

rm -f "$TMP_ROOT/data/"*
set +e
output=$(FM_TEST_COMPUTE_RUN_SECS=1 SCENARIO=gitlab-timeout "$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 0 "$result" "$output"
[ -e "$TMP_ROOT/data/cancelled" ] || fail 'GitLab execution timeout fallback did not cancel the owned pipeline'
assert_contains "$output" 'GitLab run exceeded 1s; falling back to local admission' 'GitLab execution timeout did not name its fallback reason'
assert_contains "$output" 'local:' 'confirmed GitLab execution timeout should fall back'
pass 'a confirmed GitLab execution timeout falls through after cancellation'

run_route gitlab-incomplete
expect_code 0 "$result" "$output"
assert_contains "$output" 'GitLab returned incomplete receipts; falling back to local admission' 'incomplete GitLab receipts did not name their fallback reason'
assert_contains "$output" 'local:' 'incomplete GitLab receipts should fall back'
pass 'GitLab completion with missing receipts falls through to local admission'

run_route gitlab-failure
expect_code 1 "$result" "$output"
[[ "$output" != *'local:'* ]] || fail 'a GitLab test failure with complete receipts fell back locally'
assert_contains "$output" 'Hosted partition failed: portable-parallel-1' 'GitLab test failure evidence was not preserved'
pass 'a GitLab test failure with complete receipts still fails'
for scenario in gitlab-pipeline-ambiguous gitlab-invalid-id gitlab-status-failure gitlab-jobs-failure gitlab-artifact-failure gitlab-bad-artifact gitlab-bootstrap-failure gitlab-canceled-green gitlab-queue-cancel-failure; do
  run_route "$scenario"
  expect_code 77 "$result" "$scenario must be indeterminate, not a test or lint verdict: $output"
  [[ "$output" != *'local:'* ]] || fail "$scenario fell back locally"
  assert_contains "$output" 'failing closed' "$scenario did not name its fail-closed reason"
  pass "$scenario fails closed with a diagnostic"
done
for scenario in gitlab-malformed-jobs gitlab-bad-jobs; do
  run_route "$scenario"
  expect_code 77 "$result" "$scenario must be indeterminate, not a test or lint verdict: $output"
  [[ "$output" != *'local:'* ]] || fail "$scenario fell back locally"
  assert_contains "$output" 'GitLab returned an invalid job listing' "$scenario did not name its fail-closed reason"
  pass "$scenario fails closed with a diagnostic"
done
for scenario in github-race-failed github-race-success; do
  run_route "$scenario"
  expect_code 77 "$result" "$scenario must fail closed after a terminal completion race: $output"
  [[ "$output" != *'local:'* ]] || fail "$scenario fell back after the GitHub run completed"
  [[ "$(cat "$TMP_ROOT/data/calls")" != *'gitlab '* ]] || fail "$scenario reached GitLab after GitHub completed"
  pass "$scenario cannot treat GitHub completion as cancellation"
done
run_route github-canceled-green
expect_code 77 "$result" "$output"
[[ "$output" != *'local:'* ]] || fail 'a completed GitHub run with verified receipts fell back locally'
assert_contains "$output" 'receipts: verified' 'the completed run must verify its green receipts before the conclusion check'
assert_contains "$output" 'GitHub run 123 finished cancelled with verified receipts' 'a non-success GitHub conclusion did not name its fail-closed reason'
[[ "$(cat "$TMP_ROOT/data/calls")" != *'gitlab '* ]] || fail 'a completed non-success GitHub run reached GitLab'
pass 'a completed GitHub run that is not a success is indeterminate, not a test verdict'
for scenario in gitlab-success gitlab-bootstrap; do
  run_route "$scenario"
  expect_code 0 "$result" "$output"
  assert_contains "$output" 'GitLab evidence' 'GitLab evidence must return to Test'
  [[ "$output" != *'local:'* ]] || fail 'successful GitLab run fell back'
  if [ "$scenario" = gitlab-bootstrap ]; then
    [ -e "$TMP_ROOT/data/bootstrapped" ] || fail 'empty dedicated project was not bootstrapped'
    python3 - "$TMP_ROOT/data/bootstrap.json" "$ROOT/.github/workflows/test-compute.gitlab.template" <<'PY'
import json,pathlib,sys
bootstrap=json.load(open(sys.argv[1])); actions=bootstrap['actions']
assert len(actions)==1 and actions[0]['file_path']=='.gitlab-ci.yml'
assert actions[0]['content']==pathlib.Path(sys.argv[2]).read_text()
PY
  fi
  pass "$scenario executes only after GitHub unavailability and authentication"
done
run_route gitlab-forbidden
expect_code 0 "$result" "$output"
assert_contains "$output" 'local:' 'GitLab variable permission rejection did not fall back'
pass 'structured GitLab variable permission refusal falls back without duplicate dispatch'
run_route gitlab-quota
expect_code 0 "$result" "$output"
assert_contains "$output" 'local:' 'GitLab quota exhaustion did not fall back'
pass 'GitLab jobs rejected before start for exhausted compute fall back automatically'
for scenario in gitlab-race-success gitlab-race-failed; do
  run_route "$scenario"
  expect_code 77 "$result" "$scenario must be indeterminate after a terminal completion race: $output"
  [[ "$output" != *'local:'* ]] || fail "$scenario fell back after the GitLab pipeline completed"
  pass "$scenario cannot treat GitLab completion as cancellation"
done
run_route private
expect_code 0 "$result" "$output"
[[ "$output" == *'local:'* ]] || fail 'private source was relayed'
[[ "$(cat "$TMP_ROOT/data/calls")" != *gitlab* ]] || fail 'private source reached GitLab'
pass 'private repositories cannot enter a public source relay'
# Payload from a successful call supports a real bundle restore, not a source snapshot assertion.
run_route success
python3 - "$TMP_ROOT/data/request" "$TMP_ROOT/payload.json" <<'PY'
import json,sys
open(sys.argv[2],'w').write(json.load(open(sys.argv[1]))['inputs']['snapshot'])
PY
git -C "$fixture" checkout -q --detach "$base"
"$router" restore "$TMP_ROOT/payload.json" > "$TMP_ROOT/restore.log" 2>&1
[ "$(git -C "$fixture" rev-parse HEAD)" = "$sha" ] || fail 'bundle restore changed commit identity'
[ -f "$fixture/tests/sample.test.sh" ] || fail 'bundle did not restore committed file'
pass 'unpushed git bundle restores the exact committed head'
SUITE_RC=7 "$router" worker portable-parallel-1 "$TMP_ROOT/worker" "$TMP_ROOT/payload.json" > "$TMP_ROOT/worker.log" 2>&1 && fail 'worker hid test exit' || rc=$?
expect_code 1 "$rc" 'failed worker returns failure'
python3 - "$TMP_ROOT/worker/result.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert r['exit']==7 and r['scripts']==['tests/sample.test.sh']
PY
pass 'worker captures actual test exit and exact script evidence'
"$router" worker lint-2 "$TMP_ROOT/lint" "$TMP_ROOT/payload.json" > "$TMP_ROOT/lint.log" 2>&1
assert_contains "$(cat "$TMP_ROOT/lint.log")" '<2of4>' 'canonical lint partition was not run'
pass 'lint worker invokes the canonical partition interface'
rm -f "$TMP_ROOT/data/"*
output=$("$router" test --list --all)
assert_contains "$output" 'local: <--list> <--all>' 'inspection argument semantics drifted'
[ ! -e "$TMP_ROOT/data/calls" ] || fail 'inspection contacted hosted services'
pass 'inspection never contacts hosted services'
rm -f "$TMP_ROOT/data/"*
set +e
output=$("$router" test --all 2>&1)
result=$?
set -e
expect_code 0 "$result" "$output"
assert_contains "$output" 'local: <--all>' 'non-baseline test selection left local admission'
[ ! -e "$TMP_ROOT/data/calls" ] || fail 'non-baseline test selection contacted hosted services'
pass 'non-baseline test selections stay on local admission'
printf dirty > "$fixture/untracked"
run_route success
assert_contains "$output" 'local:' 'dirty worktree was sent remotely'
[ ! -e "$TMP_ROOT/data/calls" ] || fail 'dirty snapshot contacted hosted services'
rm "$fixture/untracked"
pass 'uncommitted content always uses the existing local mirror path'
set +e
output=$("$router" unknown 2>&1); result=$?
set -e
expect_code 2 "$result" "$output"
assert_contains "$output" 'unknown command' 'usage error must explain input'
pass 'unknown commands are rejected before dependencies'
lint_fixture="$TMP_ROOT/local-lint-repo"
mkdir -p "$lint_fixture/bin"
cp "$ROOT/bin/fm-pc02-test-offload.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-pc02-hygiene-lib.sh" "$lint_fixture/bin/"
cat > "$lint_fixture/bin/fm-lint.sh" <<'LINT'
#!/usr/bin/env bash
printf 'changed-file-lint argv=%s\n' "$*"
exit "${LINT_RC:-0}"
LINT
cat > "$lint_fixture/bin/fm-test-compute.sh" <<'LINTWORKER'
#!/usr/bin/env bash
printf 'canonical-lint %s\n' "$*"
exit 0
LINTWORKER
chmod +x "$lint_fixture/bin/"*.sh
set +e
output=$(FM_PC02_OFFLOAD_DISABLE=1 LINT_RC=9 "$lint_fixture/bin/fm-pc02-test-offload.sh" --lint-partitions 2>&1)
status=$?
set -e
expect_code 9 "$status" "PC01 lint fallback must return the changed-file lint status: $output"
assert_contains "$output" 'changed-file-lint argv=' 'PC01 lint fallback did not run bin/fm-lint.sh'
[[ "$output" != *'argv=--partition'* ]] || fail 'PC01 lint fallback passed canonical partition arguments'
[[ "$output" != *'canonical-lint'* ]] || fail 'PC01 lint fallback ran the canonical local-lint mode'
output=$("$router" local-lint)
for n in 1 2 3 4; do assert_contains "$output" "<${n}of4>" 'local canonical lint omitted a partition'; done
pass 'PC01 lint fallback runs changed-file lint while local-lint keeps canonical partitions'
# The bound is a hard ceiling: with two allowed, never more than two partitions
# overlap, while all four still run. The trace records real process overlap.
lint_trace="$TMP_ROOT/local-lint-trace"
: > "$lint_trace"
output=$(LINT_TRACE="$lint_trace" LINT_SLEEP_SECS=1 FM_PC02_LINT_PARALLEL=2 "$router" local-lint 2>&1)
for n in 1 2 3 4; do assert_contains "$output" "<${n}of4>" 'bounded local lint omitted a partition'; done
peak=$(awk '$1 == "start" { running++; if (running > peak) peak = running } $1 == "end" { running-- } END { print peak + 0 }' "$lint_trace")
[ "$peak" -eq 2 ] || fail "FM_PC02_LINT_PARALLEL=2 overlapped $peak partitions, expected 2"
pass 'local-lint runs canonical partitions concurrently under its bound'
# The default stays serial, so existing local behavior is unchanged.
: > "$lint_trace"
LINT_TRACE="$lint_trace" LINT_SLEEP_SECS=1 "$router" local-lint > /dev/null 2>&1
peak=$(awk '$1 == "start" { running++; if (running > peak) peak = running } $1 == "end" { running-- } END { print peak + 0 }' "$lint_trace")
[ "$peak" -eq 1 ] || fail "default local-lint overlapped $peak partitions, expected serial execution"
pass 'local-lint stays serial unless the offload sets a bound'
# Aggregate status keeps serial semantics: one failed partition fails the run
# with status 1 while every other partition still runs.
set +e
output=$(FM_PC02_LINT_PARALLEL=2 LINT_FAIL_PARTITION=3of4 LINT_FAIL_RC=7 "$router" local-lint 2>&1)
result=$?
set -e
expect_code 1 "$result" "a failed canonical partition must aggregate to 1: $output"
for n in 1 2 3 4; do assert_contains "$output" "<${n}of4>" 'aggregate lint run skipped a partition after a failure'; done
pass 'concurrent local-lint keeps the serial aggregate status'
# A malformed bound fails closed instead of guessing a concurrency.
set +e
output=$(FM_PC02_LINT_PARALLEL=0 "$router" local-lint 2>&1)
result=$?
set -e
expect_code 1 "$result" "a zero lint bound must fail closed: $output"
assert_contains "$output" 'FM_PC02_LINT_PARALLEL must be a positive integer' 'a malformed lint bound did not name its failure'
pass 'a malformed local-lint concurrency bound fails closed'
# The canonical count is owned by bin/fm-lint.sh; the stub answers it from LINT_PARTITION_COUNT.
set +e
output=$(LINT_PARTITION_COUNT=9 SCENARIO=success "$router" lint 2>&1)
result=$?
set -e
expect_code 0 "$result" "$output"
assert_contains "$output" 'result: success' 'changed-count hosted lint must prove success'
[[ "$output" != *'local:'* ]] || fail 'changed-count hosted lint fell back locally'
python3 - "$TMP_ROOT/data/request" <<'PY'
import json,sys
request=json.load(open(sys.argv[1]))
payload=json.loads(request['inputs']['snapshot'])
assert payload['kind']=='lint' and set(payload['partitions'])=={f'lint-{n}' for n in range(1,10)}, payload['partitions']
PY
pass 'a changed canonical lint count reaches every hosted lint partition'
set +e
output=$(LINT_PARTITION_COUNT=9 "$router" local-lint 2>&1)
result=$?
set -e
expect_code 0 "$result" "$output"
for n in 1 2 3 4 5 6 7 8 9; do assert_contains "$output" "<${n}of9>" 'changed-count local lint omitted a partition'; done
[[ "$output" != *'of4'* ]] || fail 'local lint still restates the four-partition count'
pass 'a changed canonical lint count reaches every local lint partition'
LINT_PARTITION_COUNT=9 "$router" worker lint-9 "$TMP_ROOT/lint-nine" "$TMP_ROOT/payload.json" > "$TMP_ROOT/lint-nine.log" 2>&1 || fail 'changed-count lint worker did not run its last partition'
assert_contains "$(cat "$TMP_ROOT/lint-nine.log")" '<9of9>' 'changed-count lint worker did not run its last partition'
if LINT_PARTITION_COUNT=9 "$router" worker lint-10 "$TMP_ROOT/lint-ten" "$TMP_ROOT/payload.json" > "$TMP_ROOT/lint-ten.log" 2>&1; then
  fail 'lint worker accepted a partition beyond the canonical count'
fi
[[ "$(cat "$TMP_ROOT/lint-ten.log")" != *'<10of9>'* ]] || fail 'lint worker ran a partition beyond the canonical count'
pass 'a changed canonical lint count bounds the lint workers it accepts'
for bad in 0 x; do
  set +e
  output=$(LINT_PARTITION_COUNT=$bad "$router" local-lint 2>&1)
  result=$?
  set -e
  expect_code 1 "$result" "$output"
  [[ "$output" != *'lint:'* ]] || fail "an unusable canonical count ($bad) still ran lint partitions"
  assert_contains "$output" 'canonical lint partition count unavailable' "unusable canonical count ($bad) did not name its failure"
  rm -f "$TMP_ROOT/data/"*
  set +e
  output=$(LINT_PARTITION_COUNT=$bad SCENARIO=success "$router" lint 2>&1)
  result=$?
  set -e
  expect_code 1 "$result" "$output"
  [[ "$output" != *'local:'* ]] || fail "an unusable canonical count ($bad) fell back to a local lint"
  [ ! -e "$TMP_ROOT/data/request" ] || fail "an unusable canonical count ($bad) dispatched hosted lint"
done
pass 'an unusable canonical lint count fails closed on every lint path'

origin_original=$(git -C "$fixture" remote get-url origin)
git -C "$fixture" remote set-url origin https://github.com/example/other.git
rm -f "$TMP_ROOT/data/"*
set +e
output=$("$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 0 "$result" "$output"
assert_contains "$output" 'source is outside public Firstmate scope' 'outside-repository source did not name its local fallback reason'
[ ! -e "$TMP_ROOT/data/calls" ] || fail 'outside-repository source contacted hosted services'
pass 'repositories outside public Firstmate fall back locally before any hosted call'
git -C "$fixture" remote set-url origin "$origin_original"

rm -f "$TMP_ROOT/data/"*
python3 -c 'import os,sys; sys.stdout.buffer.write(os.urandom(100000))' > "$fixture/tests/incompressible.bin"
git -C "$fixture" add tests/incompressible.bin
git -C "$fixture" -c user.name=Test -c user.email=test@example.invalid commit -qm 'add incompressible payload'
set +e
output=$("$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 0 "$result" "$output"
assert_contains "$output" 'snapshot exceeds dispatch input limit' 'oversized snapshot did not name its local fallback reason'
[ ! -e "$TMP_ROOT/data/calls" ] || fail 'oversized snapshot contacted hosted services'
pass 'oversized snapshots fall back locally before any hosted call'
echo '# all test-compute tests passed' 
