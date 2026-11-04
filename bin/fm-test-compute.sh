#!/usr/bin/env bash
# fm-test-compute.sh - hosted Test/lint routing, then existing PC02/PC01 fallback.
#
# Usage:
#   fm-test-compute.sh test --changed --exclude-family real-herdr-gated [--exclude-quarantined]
#   fm-test-compute.sh lint
#   fm-test-compute.sh local-lint                   (PC02/local worker only)
#   fm-test-compute.sh restore <payload-file>       (hosted worker only)
#   fm-test-compute.sh worker <partition> <output-dir> <payload-file>
#   fm-test-compute.sh --help
#
# The pinned no-mistakes Test command enters through --pc02-if-idle.
# Only that exact baseline, with or without the canonical --exclude-quarantined
# selection filter, is distributed; other arguments (including --json,
# inspection and custom selection) retain the existing PC02/local behavior.
# The baseline selection is split into hosted-capable and local-only scripts;
# no tests are omitted. The hosted subset is partitioned by the lanes reported
# by fm-test-run.sh --list-lanes, only non-empty partitions are dispatched, and
# an exact partition check gates dispatch. `test` dispatches portable test
# partitions only; `lint` runs every canonical lint partition alone on
# hosted compute or PC02, while PC01's last-resort lint is the changed-file
# subset.
#
# GitHub Actions standard ubuntu-latest is tried first, then GitLab.com on a
# dedicated project, only after `glab auth status` succeeds, then PC02/PC01.
# This first delivery accepts only public firstmate repositories on github.com;
# private repositories and other projects use the existing local path, never a
# public relay or mirror. No paid runner label or quota purchase is requested.
#
# A clean committed HEAD travels as a git bundle over the dispatch inputs,
# without publishing a GitHub ref. The payload is capped at 60000 bytes (below
# GitHub's 65535-character input limit); dirty/large/unsupported snapshots fall
# back before dispatch. The bundle requires the locally known origin/main base
# to be fetchable from the source repository. The workflow must first land on
# the source default branch; before that, dispatch automatically falls back.
#
# GitLab uses an existing dedicated project (default below), bootstrapping its
# empty repository with the public CI template on firstmate-compute. An existing
# project must have that dedicated branch installed; other branches are preserved.
# It never creates projects
# or accounts. Pipeline variables carry the same bounded public-source snapshot.
# No token is read, printed or saved by this script; glab owns authentication.
#
# Three scripts depend on local host facilities that the hosted runners do not
# provide: tests/fm-devin-harness.test.sh (jq/config-writer),
# tests/fm-calm-pi-extension.test.sh (ANSI yellow), and
# tests/fm-captain-hold-lifecycle.test.sh (request retirement). They are removed
# from the hosted payload and run through the existing PC02/PC01 admission path
# after the hosted subset succeeds; every other selected script keeps the
# GitHub then GitLab order. A local-only failure fails the routed run too.
#
# Result receipts bind every hosted partition to HEAD and the exact selected
# scripts. A test/lint failure is terminal, never grounds for a greener local
# rerun. GitHub read/receipt ambiguity fails closed. Queued admission can time
# out and fall back only after the owned run is confirmed cancelled. GitLab
# work rejected for ci_quota_exceeded before starting, a confirmed GitLab
# execution timeout, or GitLab completion with missing receipts falls through
# to local admission; a GitLab receipt showing a failed test still fails.
# Every API call is bounded. Interrupts cancel only this invocation's run.
# stdout forwards suite evidence; routing diagnostics go to stderr.
#
# Environment:
#   FM_TEST_COMPUTE_DISABLE=1   bypass hosted tiers (also in hosted workers)
# GitHub/GitLab CI environments bypass automatically; generic CI=true does not
# disable routing because no-mistakes may use it for its pre-push commands.
#   FM_TEST_COMPUTE_QUEUE_SECS  pending admission bound (default 180)
#   FM_TEST_COMPUTE_RUN_SECS    execution/monitor bound (default 10800)
#   FM_TEST_COMPUTE_POLL_SECS   foreground poll cadence (default 10)
#   FM_TEST_COMPUTE_API_SECS    per API request bound (default 30)
#   FM_TEST_COMPUTE_GITLAB_PROJECT existing dedicated GitLab project
#                              (default sean.morden1993/firstmate-ci)
# Exit: 0 proven success; 1 failed GitHub evidence, a failed hosted receipt, or
# an unreadable canonical lint partition count; 2 usage error. Unavailable
# hosted tiers fall through to PC02/PC01 admission: Test and remote lint return
# the executed command's status, while PC01's last-resort lint returns
# bin/fm-lint.sh's changed-file status. An unreadable count is the exception:
# local-lint, lint dispatch, and lint workers fail closed instead of running
# only some of the canonical partitions.
set -u
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SELF_DIR/.." && pwd)
usage() { sed -n '2,/^set -u/{ /^#/s/^# \{0,1\}//p; }' "$0"; }
error() { printf 'error: %s\nhelp: fm-test-compute.sh --help\n' "$1"; exit 2; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -v|-V|--version) echo 1; exit 0 ;;
  '') printf 'bin: %s\ndescription: Route Firstmate Test and canonical lint to hosted compute.\nhelp: fm-test-compute.sh --help\n' "$0"; exit 0 ;;
  test|lint|local-lint|restore|worker) mode=$1; shift ;;
  *) error "unknown command: $1" ;;
esac
cd "$ROOT" || exit 1
# bin/fm-lint.sh owns the canonical lint partition count; read it, never restate it.
# An empty, non-numeric, or zero count is a failure, never a silent zero-partition run;
# bin/fm-lint.sh owns the partition ceiling.
lint_partition_count() {
  local count
  count=$("$SELF_DIR/fm-lint.sh" --partition-count) || return 1
  case "$count" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$count" -gt 0 ] || return 1
  printf '%s\n' "$count"
}

if [ "$mode" = local-lint ]; then
  [ "$#" = 0 ] || error 'local-lint accepts no arguments'
  count=$(lint_partition_count) || { echo 'fm-test-compute: canonical lint partition count unavailable' >&2; exit 1; }
  rc=0
  n=1
  while [ "$n" -le "$count" ]; do "$SELF_DIR/fm-lint.sh" --partition "${n}of${count}" || rc=1; n=$((n+1)); done
  exit "$rc"
fi
# Payload unpacking uses JSON files, never shell evaluation or argv-sized JSON.
if [ "$mode" = restore ]; then
  [ "$#" = 1 ] || error 'restore requires a payload file'
  python3 - "$1" <<'PY'
import base64, json, pathlib, subprocess, sys
p=json.load(open(sys.argv[1]))
assert p['version']==1 and len(p['sha'])==40 and len(p['base'])==40
bundle=pathlib.Path(sys.argv[1]).with_suffix('.bundle')
bundle.write_bytes(base64.b64decode(p['bundle'], validate=True))
if p['bundle']:
    subprocess.run(['git','bundle','verify',str(bundle)],check=True)
    subprocess.run(['git','fetch',str(bundle),'HEAD'],check=True)
subprocess.run(['git','checkout','--detach',p['sha']],check=True)
assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()==p['sha']
subprocess.run(['git','update-ref','refs/remotes/origin/main',p['base']],check=True)
PY
  exit $?
fi
if [ "$mode" = worker ]; then
  [ "$#" = 3 ] || error 'worker requires partition, output directory, payload file'
  partition=$1; output=$2; payload=$3
  mkdir -p "$output" || exit 1
  export FM_TEST_COMPUTE_DISABLE=1
  lint_count=0
  case "$partition" in
    lint-*) lint_count=$(lint_partition_count) || { echo 'fm-test-compute: canonical lint partition count unavailable' >&2; exit 1; } ;;
  esac
  python3 - "$partition" "$output" "$payload" "$lint_count" <<'PY'
import json, os, pathlib, subprocess, sys
part, out, payload, lint_count=sys.argv[1:]
p=json.load(open(payload)); out=pathlib.Path(out)
assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()==p['sha']
selected=[]
if part.startswith('lint-'):
    n=int(part[5:]); count=int(lint_count); assert 1<=n<=count
    cmd=['bin/fm-lint.sh','--partition',f'{n}of{count}','--telemetry',str(out/'lint.tsv')]
else:
    selected=p['partitions'][part]
    cmd=['bin/fm-test-run.sh',*selected,'--jobs','1','--per-script-timeout-secs','1500','--json',str(out/'timing.json')]
rc=0
if part.startswith('lint-') or selected:
    with open(out/'run.log','w') as log:
        env=os.environ.copy()
        if part.startswith('lint-'):
            env['FM_LINT_REQUIRE_BOUNDS']='1'
            env['FM_LINT_JOBS']='1'
        rc=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,env=env).returncode
    print((out/'run.log').read_text(),end='')
(out/'result.json').write_text(json.dumps(dict(version=1,sha=p['sha'],partition=part,scripts=selected,exit=rc)))
sys.exit(0 if rc==0 else 1)
PY
  exit $?
fi
ARGS=("$@")
# These tests need local host facilities the hosted runners do not provide.
# Their assertions stay in the selection; they run on PC02/PC01 instead.
NOT_HOSTED_SCRIPTS=(
  tests/fm-devin-harness.test.sh
  tests/fm-calm-pi-extension.test.sh
  tests/fm-captain-hold-lifecycle.test.sh
)
if [ "$mode" = lint ] && [ "$#" != 0 ]; then error 'lint accepts no arguments'; fi
for name in QUEUE RUN POLL API; do
  case "$name" in QUEUE) value=${FM_TEST_COMPUTE_QUEUE_SECS:-180} ;; RUN) value=${FM_TEST_COMPUTE_RUN_SECS:-10800} ;; POLL) value=${FM_TEST_COMPUTE_POLL_SECS:-10} ;; API) value=${FM_TEST_COMPUTE_API_SECS:-30} ;; esac
  case "$value" in ''|*[!0-9]*|0) error "FM_TEST_COMPUTE_${name}_SECS must be a positive integer" ;; esac
  printf -v "$name" '%s' "$value"
done
local_run() {
  echo "fm-test-compute: $1; falling back to local admission" >&2
  if [ -n "${work:-}" ]; then rm -rf "$work"; fi
  if [ "$mode" = test ]; then exec "$SELF_DIR/fm-pc02-test-offload.sh" "${ARGS[@]}"; fi
  exec "$SELF_DIR/fm-pc02-test-offload.sh" --lint-partitions
}
# Preserve all semantics for unsupported commands; inspection never contacts APIs.
if [ "$mode" = test ]; then
  case " $* " in
    " --changed --exclude-family real-herdr-gated " | " --changed --exclude-family real-herdr-gated --exclude-quarantined ") ;;
    *) exec "$SELF_DIR/fm-pc02-test-offload.sh" "${ARGS[@]}" ;;
  esac
fi
[ "${FM_TEST_COMPUTE_DISABLE:-}" != 1 ] && [ "${GITHUB_ACTIONS:-}" != true ] && [ "${GITLAB_CI:-}" != true ] || local_run 'hosted routing disabled'
for tool in python3 git timeout gh-axi; do command -v "$tool" >/dev/null || local_run "$tool unavailable"; done
[ -z "$(git status --porcelain)" ] || local_run 'snapshot is not committed and clean'
remote=$(git remote get-url origin 2>/dev/null) || local_run 'no source origin'
case "$remote" in
  https://github.com/*) repo=${remote#https://github.com/} ;;
  git@github.com:*) repo=${remote#git@github.com:} ;;
  *) local_run 'source is not github.com' ;;
esac
repo=${repo%.git}
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/firstmate$ ]] || local_run 'source is outside public Firstmate scope'
api() { timeout "$API" gh-axi api "$@" --full; }
base=$(git rev-parse --verify origin/main 2>/dev/null) || local_run 'origin/main unavailable'
sha=$(git rev-parse HEAD) || exit 1
git merge-base --is-ancestor "$base" "$sha" || local_run 'origin/main is not an ancestor of HEAD'
work=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-compute.XXXXXX") || exit 1
chmod 700 "$work"
run_id=; tier=; finished=0
cancel() {
  [ -n "$run_id" ] || return 0
  if [ "$tier" = github ]; then
    api POST "/repos/$repo/actions/runs/$run_id/cancel" > /dev/null 2>&1 || true
    local state attempt
    for attempt in 1 2 3 4 5 6; do
      state=$(api "/repos/$repo/actions/runs/$run_id" --jq '[.status,.conclusion] | @tsv') || return 1
      local conclusion
      IFS=$'\t' read -r state conclusion <<< "$state"
      if [ "$state" = completed ]; then
        [ "$conclusion" = cancelled ] && return 0
        return 1
      fi
      echo "fm-test-compute: waiting for owned run cancellation ($attempt/6)" >&2
      sleep "$POLL"
    done
    return 1
  else
    timeout "$API" glab api --hostname gitlab.com --method POST "projects/$project/pipelines/$run_id/cancel" > /dev/null 2>&1 || return 1
    local state attempt
    for attempt in 1 2 3 4 5 6; do
      state=$(timeout "$API" glab api --hostname gitlab.com "projects/$project/pipelines/$run_id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])') || return 1
      [ "$state" = canceled ] && return 0
      case "$state" in success|failed|skipped) return 1 ;; esac
      echo "fm-test-compute: waiting for owned run cancellation ($attempt/6)" >&2
      sleep "$POLL"
    done
    return 1
  fi
}
# shellcheck disable=SC2329 # Invoked by EXIT trap.
cleanup() { if [ "$finished" = 0 ]; then cancel || true; fi; rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$base" != "$sha" ]; then
  git bundle create "$work/source.bundle" HEAD "^$base" || local_run 'cannot bundle snapshot'
else
  : > "$work/source.bundle"
fi
if [ "$mode" = test ]; then
  "$SELF_DIR/fm-test-run.sh" "${ARGS[@]}" --list > "$work/selected" || local_run 'test selection cannot be listed'
  python3 - "$work" "${NOT_HOSTED_SCRIPTS[@]}" <<'PY' || local_run 'selection cannot be split without loss'
import pathlib, sys
w=pathlib.Path(sys.argv[1]); non_hosted=set(sys.argv[2:])
selected=(w/'selected').read_text().splitlines()
(w/'local-only').write_text(''.join(s+'\n' for s in selected if s in non_hosted))
(w/'selected').write_text(''.join(s+'\n' for s in selected if s not in non_hosted))
PY
else
  : > "$work/selected"
  : > "$work/local-only"
fi
# Derive the dispatchable lane set from the runner that owns lane composition.
if [ "$mode" = test ]; then
  "$SELF_DIR/fm-test-run.sh" --list-lanes > "$work/lane-names" || local_run 'lane listing unavailable'
  python3 - "$work/lane-names" "$work/dispatch-lanes" <<'PY' || local_run 'lane listing is not dispatchable'
import pathlib,re,sys
lanes=pathlib.Path(sys.argv[1]).read_text().splitlines()
dispatch=[l for l in lanes if re.fullmatch(r'portable-(?:parallel|serial)-[0-9]+(?:of[0-9]+)?', l)]
if not dispatch: raise SystemExit(1)
pathlib.Path(sys.argv[2]).write_text(''.join(l+'\n' for l in dispatch))
PY
  mkdir -p "$work/lanes"
  while IFS= read -r lane; do
    "$SELF_DIR/fm-test-run.sh" --list --lane "$lane" > "$work/lanes/$lane" || local_run "lane $lane cannot be listed"
  done < "$work/dispatch-lanes"
fi
lint_count=
if [ "$mode" = lint ]; then
  lint_count=$(lint_partition_count) || { echo 'fm-test-compute: canonical lint partition count unavailable; failing closed' >&2; exit 1; }
fi
if ! python3 - "$work" "$sha" "$base" "$repo" "$mode" "$lint_count" <<'PY'
import base64, collections, json, pathlib, sys
w=pathlib.Path(sys.argv[1]); sha,base,repo,mode,lint_count=sys.argv[2:]
selected=(w/'selected').read_text().splitlines()
if mode=='test':
    parts={}
    for f in sorted((w/'lanes').iterdir()):
        scripts=[s for s in f.read_text().splitlines() if s in selected]
        if scripts: parts[f.name]=scripts
    assert collections.Counter(s for v in parts.values() for s in v)==collections.Counter(selected), 'selected tests do not exactly partition into portable lanes'
else:
    parts={f'lint-{n}':[] for n in range(1,int(lint_count)+1)}
p=dict(version=1,sha=sha,base=base,repo=repo,kind=mode,partitions=parts,bundle=base64.b64encode((w/'source.bundle').read_bytes()).decode())
(w/'payload.json').write_text(json.dumps(p,separators=(',',':')))
PY
then local_run 'selection cannot be distributed without loss'; fi
[ "$(wc -c < "$work/payload.json")" -lt 60000 ] || local_run 'snapshot exceeds dispatch input limit'
if [ "$mode" = test ] && ! python3 -c 'import json,sys; raise SystemExit(not json.load(open(sys.argv[1]))["partitions"])' "$work/payload.json"; then
  local_run 'test selection has no hosted-capable partitions'
fi
metadata=$(api "/repos/$repo" --jq '[.private,.default_branch] | @tsv') || local_run 'source visibility unavailable'
IFS=$'\t' read -r private default_branch <<< "$metadata"
[ "$private" = false ] && [[ "$default_branch" =~ ^[A-Za-z0-9_./-]+$ ]] || local_run 'private or unverified source: hosted relay forbidden'
request_id=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')
python3 - "$work" "$default_branch" "$request_id" <<'PY'
import json,pathlib,sys
w=pathlib.Path(sys.argv[1]); ref,rid=sys.argv[2:]
p=json.load(open(w/'payload.json'))
(w/'dispatch.json').write_text(json.dumps(dict(ref=ref,inputs=dict(snapshot=(w/'payload.json').read_text(),request_id=rid,partitions=json.dumps(list(p['partitions']))))))
PY
# 75 means tier unavailable before test execution; all ambiguous failures fail closed.
verify_results() {
  python3 - "$work" "$sha" "${1:-}" <<'PY'
import json,pathlib,sys
w=pathlib.Path(sys.argv[1]); p=json.load(open(w/'payload.json'))
found={}
for f in (w/'results').rglob('result.json'):
    r=json.load(open(f)); k=r['partition']
    assert k not in found and r['sha']==sys.argv[2] and r['version']==1
    assert r['scripts']==p['partitions'][k]
    found[k]=r
    if r['exit']!=0: print(f'Hosted partition failed: {k}',file=sys.stderr); sys.exit(1)
missing=set(p['partitions'])-set(found)
if missing:
    if sys.argv[3]:
        jobs=json.load(open(sys.argv[3]))
        if not found and any(j.get('failure_reason')=='ci_quota_exceeded' and not j.get('started_at') for j in jobs):
            print('GitLab free compute quota unavailable before execution',file=sys.stderr); sys.exit(75)
    print('missing hosted partition receipts: '+' '.join(sorted(missing)),file=sys.stderr)
    sys.exit(76)
print('receipts: verified\nhead: '+sys.argv[2])
PY
}
try_github() {
  tier=github
  api "/repos/$repo/actions/workflows/test-compute.yml" --jq '.state' > "$work/workflow-state" 2>/dev/null || return 75
  [ "$(cat "$work/workflow-state")" = active ] || return 75
  # A timed-out POST may have been accepted. Do not duplicate it on another tier.
  if ! api POST "/repos/$repo/actions/workflows/test-compute.yml/dispatches" --input "$work/dispatch.json" > "$work/dispatch.out" 2>&1; then
    # A definitive HTTP rejection did not accept work; transport ambiguity did.
    if grep -Eq 'HTTP (401|402|403|404|422|429)|^code: (FORBIDDEN|NOT_FOUND|UNAUTHORIZED|UNPROCESSABLE_ENTITY|RATE_LIMITED)$' "$work/dispatch.out"; then return 75; fi
    echo 'fm-test-compute: GitHub dispatch outcome is ambiguous; failing closed' >&2
    return 1
  fi
  local start now state conclusion row
  start=$(date +%s)
  while :; do
    row=$(api "/repos/$repo/actions/workflows/test-compute.yml/runs?event=workflow_dispatch&per_page=100" --jq ".workflow_runs[] | select(.display_title == \"fm-test-compute-$request_id\") | [.id,.status,.conclusion] | @tsv") || { echo 'fm-test-compute: GitHub run discovery request failed; failing closed' >&2; return 1; }
    if [ -n "$row" ]; then
      IFS=$'\t' read -r run_id state conclusion <<< "$row"
      [[ "$run_id" =~ ^[0-9]+$ ]] || { echo 'fm-test-compute: GitHub returned an invalid run id; failing closed' >&2; return 1; }
      echo "fm-test-compute: https://github.com/$repo/actions/runs/$run_id ($state)" >&2
      break
    fi
    now=$(date +%s)
    # Accepted but undiscovered dispatch cannot safely be duplicated.
    if [ "$((now-start))" -ge "$QUEUE" ]; then
      echo "fm-test-compute: GitHub dispatch was accepted but no run appeared within ${QUEUE}s; failing closed" >&2
      return 1
    fi
    sleep "$POLL"
  done
  start=$(date +%s)
  while :; do
    row=$(api "/repos/$repo/actions/runs/$run_id" --jq '[.status,.conclusion] | @tsv') || { echo "fm-test-compute: GitHub run observation failed for run $run_id; failing closed" >&2; return 1; }
    IFS=$'\t' read -r state conclusion <<< "$row"
    [ "$state" != completed ] || break
    now=$(date +%s)
    case "$state" in queued|waiting|requested|pending)
      if [ "$((now-start))" -ge "$QUEUE" ]; then
        cancel || { echo "fm-test-compute: GitHub run $run_id cancellation was not confirmed; failing closed" >&2; return 1; }
        finished=1; return 75
      fi ;;
    esac
    if [ "$((now-start))" -ge "$RUN" ]; then
      if cancel; then
        echo "fm-test-compute: GitHub run $run_id exceeded ${RUN}s; failing closed" >&2
      else
        echo "fm-test-compute: GitHub run $run_id exceeded ${RUN}s and cancellation was not confirmed; failing closed" >&2
      fi
      return 1
    fi
    sleep "$POLL"
  done
  finished=1
  case "$conclusion" in startup_failure|action_required) return 75 ;; esac
  timeout "$API" gh-axi run download "$run_id" -R "$repo" --dir "$work/results" > /dev/null || { echo "fm-test-compute: GitHub evidence download failed for run $run_id; failing closed" >&2; return 1; }
  verify_results || return 1
  [ "$conclusion" = success ]
}
try_gitlab() {
  tier=gitlab; run_id=; finished=0
  command -v glab >/dev/null || return 75
  timeout "$API" glab auth status --hostname gitlab.com > /dev/null 2>&1 || return 75
  local info empty ref state start now job_id
  project=${FM_TEST_COMPUTE_GITLAB_PROJECT:-sean.morden1993/firstmate-ci}
  [[ "$project" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 75
  project=${project//\//%2F}
  info=$(timeout "$API" glab api --hostname gitlab.com "projects/$project") || return 75
  empty=$(printf '%s' "$info" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["empty_repo"]).lower())') || return 75
  if [ "$empty" = true ]; then
    python3 - "$ROOT" "$work" <<'PY'
import json,pathlib,sys
root,w=map(pathlib.Path,sys.argv[1:])
(w/'bootstrap.json').write_text(json.dumps(dict(branch='firstmate-compute',commit_message='ci: bootstrap public Firstmate compute relay',actions=[dict(action='create',file_path='.gitlab-ci.yml',content=(root/'.github/workflows/test-compute.gitlab.template').read_text())])))
PY
    timeout "$API" glab api --hostname gitlab.com --method POST "projects/$project/repository/commits" --input "$work/bootstrap.json" > /dev/null || return 1
    ref=firstmate-compute
  else
    ref=firstmate-compute
    timeout "$API" glab api --hostname gitlab.com "projects/$project/repository/branches/$ref" > /dev/null 2>&1 || return 75
  fi
  python3 - "$work" "$ref" <<'PY'
import json,pathlib,sys
w=pathlib.Path(sys.argv[1]); p=json.load(open(w/'payload.json'))
(w/'gitlab.json').write_text(json.dumps(dict(ref=sys.argv[2],variables=[dict(key='FM_COMPUTE_SNAPSHOT',value=(w/'payload.json').read_text()),dict(key='FM_COMPUTE_REPO',value=p['repo'])])))
PY
  if ! timeout "$API" glab api --hostname gitlab.com --method POST "projects/$project/pipeline" --input "$work/gitlab.json" > "$work/pipeline.json" 2> "$work/gitlab-error"; then
    if grep -Eq '(HTTP |status code: |status: )(400|401|402|403|404|422|429)' "$work/gitlab-error"; then return 75; fi
    # glab emits some definitive API rejections as a map without HTTP status.
    # Match the structured server refusal, never a transport timeout or 5xx.
    if python3 - "$work/pipeline.json" <<'PY_REJECTION'
import json,sys
try:
    p=json.load(open(sys.argv[1]))
    refused=p.get('message',{}).get('base',[])
    sys.exit(0 if 'Insufficient permissions to set pipeline variables' in refused else 1)
except (ValueError,AttributeError):
    sys.exit(1)
PY_REJECTION
    then return 75; fi
    return 1
  fi
  run_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$work/pipeline.json") || return 1
  [[ "$run_id" =~ ^[0-9]+$ ]] || return 1
  echo "fm-test-compute: GitLab pipeline $run_id in ${project//%2F/\/}" >&2
  start=$(date +%s)
  while :; do
    state=$(timeout "$API" glab api --hostname gitlab.com "projects/$project/pipelines/$run_id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])') || return 1
    case "$state" in success|failed|canceled|skipped) break ;; esac
    now=$(date +%s)
    case "$state" in pending|created|manual|scheduled|waiting_for_resource)
      if [ "$((now-start))" -ge "$QUEUE" ]; then cancel || return 1; finished=1; return 75; fi ;;
    esac
    if [ "$((now-start))" -ge "$RUN" ]; then
      if cancel; then
        finished=1
        echo "fm-test-compute: GitLab run exceeded ${RUN}s; falling back to local admission" >&2
        return 75
      fi
      return 1
    fi
    sleep "$POLL"
  done
  finished=1
  timeout "$API" glab api --hostname gitlab.com "projects/$project/pipelines/$run_id/jobs?per_page=100" > "$work/jobs.json" || return 1
  python3 - "$work/jobs.json" <<'PY' > "$work/jobs"
import json,sys
for j in json.load(open(sys.argv[1])):
    if j.get('artifacts_file'): print(j['id'])
PY
  mkdir -p "$work/results"
  while IFS= read -r job_id; do
    [[ "$job_id" =~ ^[0-9]+$ ]] || return 1
    timeout "$API" glab api --hostname gitlab.com "projects/$project/jobs/$job_id/artifacts" > "$work/$job_id.zip" || return 1
    python3 - "$work" "$job_id" <<'PY' || return 1
import pathlib,sys,zipfile
w=pathlib.Path(sys.argv[1]); out=w/'results'/sys.argv[2]; out.mkdir()
with zipfile.ZipFile(w/(sys.argv[2]+'.zip')) as z:
    for name in z.namelist():
        rel=pathlib.PurePosixPath(name)
        if rel.is_absolute() or '..' in rel.parts or rel.name not in ('result.json','run.log'): continue
        target=out.joinpath(*rel.parts); target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(z.read(name))
PY
  done < "$work/jobs"
  local result_rc
  verify_results "$work/jobs.json"
  result_rc=$?
  if [ "$result_rc" = 76 ]; then
    echo 'fm-test-compute: GitLab returned incomplete receipts; falling back to local admission' >&2
    return 75
  fi
  [ "$result_rc" = 0 ] || return "$result_rc"
  [ "$state" = success ]
}
try_github
rc=$?
if [ "$rc" = 75 ]; then
  run_id=; finished=1
  echo 'fm-test-compute: GitHub unavailable; trying GitLab' >&2
  try_gitlab
  rc=$?
fi
if [ "$rc" = 75 ]; then
  run_id=; finished=1
  rm -rf "$work"
  local_run 'hosted tiers unavailable'
fi
# Complete the selection on the existing local admission path only after the
# hosted subset succeeded; a local-only failure is still the routed result.
if [ "$rc" = 0 ] && [ -s "$work/local-only" ]; then
  local_scripts=()
  while IFS= read -r script; do local_scripts+=("$script"); done < "$work/local-only"
  "$SELF_DIR/fm-pc02-test-offload.sh" "${local_scripts[@]}"
  rc=$?
fi
# Print test evidence on failure too; never turn a failing hosted suite green.
if [ -d "$work/results" ]; then
  while IFS= read -r log; do cat "$log"; done < <(find "$work/results" -name run.log -type f | LC_ALL=C sort)
fi
if [ "$rc" = 0 ]; then printf 'result: success\nhead: %s\n' "$sha"; fi
exit "$rc"
