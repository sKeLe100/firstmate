#!/usr/bin/env bash
# Hosted routing protocol regression: public-source bundles, exact receipts,
# failures, queue cancellation, GitLab admission, and unchanged local selection.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-compute)
fixture="$TMP_ROOT/repo"
mkdir -p "$fixture/bin" "$fixture/tests" "$fixture/.github/workflows" "$TMP_ROOT/tools" "$TMP_ROOT/data"
cp "$ROOT/bin/fm-test-compute.sh" "$fixture/bin/"
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
printf 'lint:'; printf ' <%s>' "$@"; echo
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
import json,os,pathlib,sys
args=sys.argv[1:]; w=pathlib.Path(os.environ['TEST_COMPUTE_DATA']); scenario=os.environ.get('SCENARIO','success')
with open(w/'calls','a') as f: f.write('github '+ ' '.join(args[:3])+'\n')
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
    (w/'cancelled').touch(); sys.exit(0)
if path.endswith('/dispatches'):
    if scenario=='dispatch-ambiguous': sys.exit(1)
    if scenario=='quota': print('error: HTTP 403 billing unavailable'); sys.exit(1)
    (w/'request').write_text(pathlib.Path(a[a.index('--input')+1]).read_text()); sys.exit(0)
if '/workflows/test-compute.yml/runs?' in path:
    if scenario=='discovery-failure': sys.exit(1)
    if scenario=='invalid-run-id': print('not-an-id\tqueued\t'); sys.exit(0)
    if scenario=='undiscovered': sys.exit(0)
    print('123\tqueued\t'); sys.exit(0)
if path.endswith('/actions/runs/123'):
    if scenario=='observation-failure': sys.exit(1)
    if scenario.startswith('github-race-'):
        state='completed' if (w/'cancelled').exists() else 'queued'
        conclusion=scenario.removeprefix('github-race-') if state=='completed' else ''
        print(state+'\t'+conclusion); sys.exit(0)
    if scenario in ('github-timeout','github-timeout-cancel-failure') and any('.status' in arg for arg in args):
        print('completed\tcancelled' if (w/'cancelled').exists() else 'running\t')
        sys.exit(0)
    if scenario in ('queued','cancel-failure') and any('.status' in arg for arg in args):
        print('queued\t' if scenario=='cancel-failure' or not (w/'cancelled').exists() else 'completed\tcancelled')
        sys.exit(0)
    if scenario=='queued' and not (w/'cancelled').exists(): print('queued\t')
    else: print('completed\t'+('failure' if scenario=='failure' else 'success'))
    sys.exit(0)
if path.endswith('/workflows/test-compute.yml'):
    if scenario in ('github-unavailable','gitlab-success','gitlab-bootstrap','gitlab-quota','gitlab-forbidden','gitlab-queued','gitlab-timeout','gitlab-incomplete','gitlab-failure','gitlab-race-success','gitlab-race-failed'): sys.exit(1)
    print('active'); sys.exit(0)
if path=='/repos/example/firstmate': print(('true' if scenario=='private' else 'false')+'\tmain'); sys.exit(0)
sys.exit(1)
MOCK
cat > "$TMP_ROOT/tools/glab" <<'MOCK'
#!/usr/bin/env python3
import json,os,pathlib,sys,zipfile,io
args=sys.argv[1:]; w=pathlib.Path(os.environ['TEST_COMPUTE_DATA']); scenario=os.environ.get('SCENARIO','success')
with open(w/'calls','a') as f: f.write('gitlab '+' '.join(args[:4])+'\n')
if args[:2]==['auth','status']: sys.exit(0 if scenario in ('gitlab-success','gitlab-bootstrap','gitlab-quota','gitlab-forbidden','gitlab-queued','gitlab-timeout','gitlab-incomplete','gitlab-failure','gitlab-race-success','gitlab-race-failed') else 1)
assert args[0]=='api'
path=next(x for x in args if x.startswith('projects/'))
if path.endswith('/repository/commits'):
    pathlib.Path(w/'bootstrap.json').write_text(pathlib.Path(args[args.index('--input')+1]).read_text())
    (w/'bootstrapped').touch(); print('{}'); sys.exit(0)
if path.endswith('/pipeline'):
    if scenario=='gitlab-forbidden': print(json.dumps(dict(message=dict(base=['Insufficient permissions to set pipeline variables'])))); print('glab: map[message:map[base:[Insufficient permissions to set pipeline variables]]]',file=sys.stderr); sys.exit(1)
    q=json.load(open(args[args.index('--input')+1])); p=json.loads(q['variables'][0]['value'])
    (w/'gitlab-payload').write_text(json.dumps(p)); print('{"id":456}'); sys.exit(0)
if path.endswith('/pipelines/456/cancel'):
    (w/'cancelled').touch(); print('{}'); sys.exit(0)
if path.endswith('/pipelines/456'):
    if scenario=='gitlab-quota': status='failed'
    elif scenario=='gitlab-queued': status='canceled' if (w/'cancelled').exists() else 'pending'
    elif scenario=='gitlab-timeout': status='canceled' if (w/'cancelled').exists() else 'running'
    elif scenario in ('gitlab-incomplete','gitlab-failure'): status='failed'
    elif scenario.startswith('gitlab-race-'):
        status=scenario.removeprefix('gitlab-race-') if (w/'cancelled').exists() else 'pending'
    else: status='success'
    print(json.dumps(dict(status=status))); sys.exit(0)
if path.endswith('/pipelines/456/jobs?per_page=100'):
    if scenario=='gitlab-quota': print(json.dumps([dict(id=1,name='compute',failure_reason='ci_quota_exceeded',started_at=None)]))
    else: print(json.dumps([dict(id=1,artifacts_file={'filename':'x.zip'})]))
    sys.exit(0)
if path.endswith('/artifacts'):
    p=json.load(open(w/'gitlab-payload')); b=io.BytesIO()
    with zipfile.ZipFile(b,'w') as z:
        for k in p['partitions']:
            if scenario=='gitlab-incomplete' and k=='portable-parallel-1': continue
            rc=1 if scenario=='gitlab-failure' and k=='portable-parallel-1' else 0
            result=dict(version=1,sha=p['sha'],partition=k,scripts=p['partitions'][k],exit=rc)
            z.writestr(f'result/{k}/result.json',json.dumps(result)); z.writestr(f'result/{k}/run.log','GitLab evidence\n')
    sys.stdout.buffer.write(b.getvalue()); sys.exit(0)
print(json.dumps(dict(empty_repo=scenario=='gitlab-bootstrap',default_branch='main')))
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

for scenario in failure missing wrong-head wrong-scripts dispatch-ambiguous; do
  run_route "$scenario"
  expect_code 1 "$result" "$scenario must fail closed: $output"
  [[ "$output" != *'local:'* ]] || fail "$scenario fell back locally"
  [ ! -e "$TMP_ROOT/data/gitlab-payload" ] || fail "$scenario fell through to GitLab"
  pass "$scenario cannot become a green fallback"
done
run_route missing
expect_code 1 "$result" "$output"
assert_contains "$output" 'missing hosted partition receipts:' 'missing GitHub receipts did not name the missing partitions'
run_route dispatch-ambiguous
expect_code 1 "$result" "$output"
assert_contains "$output" 'GitHub dispatch outcome is ambiguous; failing closed' 'ambiguous GitHub dispatch did not name its fail-closed reason'
for scenario in download-failure discovery-failure observation-failure invalid-run-id undiscovered cancel-failure; do
  run_route "$scenario"
  expect_code 1 "$result" "$scenario must fail closed: $output"
  [[ "$output" != *'local:'* ]] || fail "$scenario fell back locally"
  assert_contains "$output" 'failing closed' "$scenario did not name its fail-closed reason"
  [ ! -e "$TMP_ROOT/data/gitlab-payload" ] || fail "$scenario fell through to GitLab"
  pass "$scenario names its fail-closed reason"
done
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
rm -f "$TMP_ROOT/data/"*
set +e
output=$(FM_TEST_COMPUTE_RUN_SECS=1 SCENARIO=github-timeout "$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 1 "$result" "$output"
assert_contains "$output" 'GitHub run 123 exceeded 1s; failing closed' 'GitHub execution timeout did not name its fail-closed reason'
[[ "$output" != *'local:'* ]] || fail 'GitHub execution timeout fell back locally'
pass 'a GitHub execution timeout fails closed with a diagnostic'
rm -f "$TMP_ROOT/data/"*
set +e
output=$(FM_TEST_COMPUTE_RUN_SECS=1 SCENARIO=github-timeout-cancel-failure "$router" test --changed --exclude-family real-herdr-gated 2>&1)
result=$?
set -e
expect_code 1 "$result" "$output"
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
for scenario in github-race-failed github-race-success; do
  run_route "$scenario"
  expect_code 1 "$result" "$scenario must fail closed after a terminal completion race: $output"
  [[ "$output" != *'local:'* ]] || fail "$scenario fell back after the GitHub run completed"
  [[ "$(cat "$TMP_ROOT/data/calls")" != *'gitlab '* ]] || fail "$scenario reached GitLab after GitHub completed"
  pass "$scenario cannot treat GitHub completion as cancellation"
done
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
  expect_code 1 "$result" "$scenario must fail closed after a terminal completion race: $output"
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
cp "$ROOT/bin/fm-pc02-test-offload.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$lint_fixture/bin/"
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
# The canonical count is owned by bin/fm-lint.sh; the stub answers it from LINT_PARTITION_COUNT.
set +e
output=$(LINT_PARTITION_COUNT=6 SCENARIO=success "$router" lint 2>&1)
result=$?
set -e
expect_code 0 "$result" "$output"
assert_contains "$output" 'result: success' 'changed-count hosted lint must prove success'
[[ "$output" != *'local:'* ]] || fail 'changed-count hosted lint fell back locally'
python3 - "$TMP_ROOT/data/request" <<'PY'
import json,sys
request=json.load(open(sys.argv[1]))
payload=json.loads(request['inputs']['snapshot'])
assert payload['kind']=='lint' and set(payload['partitions'])=={f'lint-{n}' for n in range(1,7)}, payload['partitions']
PY
pass 'a changed canonical lint count reaches every hosted lint partition'
set +e
output=$(LINT_PARTITION_COUNT=6 "$router" local-lint 2>&1)
result=$?
set -e
expect_code 0 "$result" "$output"
for n in 1 2 3 4 5 6; do assert_contains "$output" "<${n}of6>" 'changed-count local lint omitted a partition'; done
[[ "$output" != *'of4'* ]] || fail 'local lint still restates the four-partition count'
pass 'a changed canonical lint count reaches every local lint partition'
LINT_PARTITION_COUNT=6 "$router" worker lint-6 "$TMP_ROOT/lint-six" "$TMP_ROOT/payload.json" > "$TMP_ROOT/lint-six.log" 2>&1 || fail 'changed-count lint worker did not run its last partition'
assert_contains "$(cat "$TMP_ROOT/lint-six.log")" '<6of6>' 'changed-count lint worker did not run its last partition'
if LINT_PARTITION_COUNT=6 "$router" worker lint-7 "$TMP_ROOT/lint-seven" "$TMP_ROOT/payload.json" > "$TMP_ROOT/lint-seven.log" 2>&1; then
  fail 'lint worker accepted a partition beyond the canonical count'
fi
[[ "$(cat "$TMP_ROOT/lint-seven.log")" != *'<7of6>'* ]] || fail 'lint worker ran a partition beyond the canonical count'
pass 'a changed canonical lint count bounds the lint workers it accepts'
set +e
output=$(LINT_PARTITION_COUNT=x "$router" local-lint 2>&1)
result=$?
set -e
expect_code 1 "$result" "$output"
[[ "$output" != *'lint:'* ]] || fail 'an unreadable canonical count still ran lint partitions'
assert_contains "$output" 'canonical lint partition count unavailable' 'unreadable canonical count did not name its failure'
rm -f "$TMP_ROOT/data/"*
set +e
output=$(LINT_PARTITION_COUNT=x SCENARIO=success "$router" lint 2>&1)
result=$?
set -e
expect_code 1 "$result" "$output"
[[ "$output" != *'local:'* ]] || fail 'an unreadable canonical count fell back to a local lint'
[ ! -e "$TMP_ROOT/data/request" ] || fail 'an unreadable canonical count dispatched hosted lint'
pass 'an unreadable canonical lint count fails closed on every lint path'

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
