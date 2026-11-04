#!/usr/bin/env bash
# Drive the real router (bin/fm-test-compute.sh) against the disposable
# localhost GitHub/GitLab emulator for each derived scenario.
set -u
LAB=$1
PORT=$(cat "$LAB/state/port")
EMU="http://127.0.0.1:$PORT"
REPO=${REPO:-$LAB/repo}
LOGS=${LOGS:-$LAB/logs}; mkdir -p "$LOGS"
ROUTER="$REPO/bin/fm-test-compute.sh"
results="$LOGS/results.tsv"
: > "$results"

reset_state() {  # <scenario>
  rm -f "$LAB/state/dispatch.json" "$LAB/state/run.json" "$LAB/state/cancelled" "$LAB/state/gitlab-pipeline.json"
  : > "$LAB/state/requests.log"
  printf '%s' "$1" > "$LAB/state/scenario"
}

drive() {  # <log-name> <scenario> <mode> <tools: gh|both> [args...]
  local name=$1 scen=$2 mode=$3 tools=$4; shift 4
  reset_state "$scen"
  case "$tools" in
    both) toolpath="$LAB/tools:$PATH" ;;
    gh)   toolpath="$LAB/tools-gh:$PATH" ;;
  esac
  ( cd "$REPO" && env -u CI -u GITHUB_ACTIONS -u GITLAB_CI \
      EMU_BASE="$EMU" EMU_STATE="$LAB/state" EMU_GITLAB_AUTH=1 PATH="$toolpath" \
      FM_TEST_COMPUTE_QUEUE_SECS=2 FM_TEST_COMPUTE_POLL_SECS=1 FM_TEST_COMPUTE_API_SECS=5 \
      FM_TEST_COMPUTE_DISABLE=0 FM_PC02_OFFLOAD_DISABLE=1 \
      "$ROUTER" "$mode" "$@" ) > "$LOGS/$name.log" 2>&1
  local rc=$?
  cp "$LAB/state/requests.log" "$LOGS/$name.requests" 2>/dev/null || true
  printf '%s\n' "$rc" > "$LOGS/$name.exit"
  return 0
}

record() {  # <name> <expected-rc> <observed-rc> <verdict> <note>
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$results"
}

expect() {  # <name> <expected-rc> [required-lines...]   (uses $LOGS/<name>.log)
  local name=$1 want=$2; shift 2
  local rc; rc=$(cat "$LOGS/$name.exit")
  local verdict=pass note=()
  [ "$rc" = "$want" ] || { verdict=fail; note+=("exit $rc != $want"); }
  local needle
  for needle in "$@"; do
    case "$needle" in
      !*) grep -Fq -- "${needle#!}" "$LOGS/$name.log" && { verdict=fail; note+=("unexpected: ${needle#!}"); } ;;
      *)  grep -Fq -- "$needle" "$LOGS/$name.log" || { verdict=fail; note+=("missing: $needle"); } ;;
    esac
  done
  [ -e "$LAB/state/cancelled" ] || true
  record "$name" "$want" "$rc" "$verdict" "${note[*]:-}"
}

echo "== scenario 1: lint queue timeout, confirmed cancel -> local fallback"
drive lint-queue-timeout queued-cancel lint gh
expect lint-queue-timeout 0 \
  'https://github.com/example/firstmate/actions/runs/123 (queued)' \
  'GitHub unavailable; trying GitLab' \
  'hosted tiers unavailable; falling back to local admission' \
  'fm-pc02-test-offload: offload disabled (FM_PC02_OFFLOAD_DISABLE=1); running on PC01' \
  '!linter found issues' \
  '!failing closed'
[ -e "$LAB/state/cancelled" ] && echo '  cancel request observed' || echo '  MISSING cancel request'

echo "== scenario 1b: lint queue timeout, cancellation NOT confirmed -> 77, no lint verdict"
drive lint-queue-timeout-cancel-refused queued-cancel-refused lint gh
expect lint-queue-timeout-cancel-refused 77 \
  'https://github.com/example/firstmate/actions/runs/123 (queued)' \
  'GitHub run 123 cancellation was not confirmed; failing closed' \
  '!running on PC01' \
  '!linter found issues' \
  '!local:'

echo "== scenario 2: ambiguous dispatch POST, no run listed -> local fallback"
drive lint-ambiguous-dispatch ambiguous lint gh
expect lint-ambiguous-dispatch 0 \
  'GitHub dispatch outcome is ambiguous; looking for the run' \
  'GitHub dispatch outcome stayed ambiguous and no run appeared within 2s; treating as not started' \
  'hosted tiers unavailable; falling back to local admission' \
  'fm-pc02-test-offload: offload disabled (FM_PC02_OFFLOAD_DISABLE=1); running on PC01' \
  '!linter found issues' \
  '!failing closed'

echo "== scenario 3a: accepted dispatch, run never listed -> fail closed 77 (lint)"
drive lint-accepted-undiscovered accepted-undiscovered lint gh
expect lint-accepted-undiscovered 77 \
  'GitHub dispatch was accepted but no run appeared within 2s; failing closed' \
  '!running on PC01' \
  '!local:'

echo "== scenario 3b: accepted dispatch, run never listed -> fail closed 77 (test)"
drive test-accepted-undiscovered accepted-undiscovered test gh --changed --exclude-family real-herdr-gated --exclude-quarantined
expect test-accepted-undiscovered 77 \
  'GitHub dispatch was accepted but no run appeared within 2s; failing closed' \
  '!running on PC01'

echo "== scenario 4: completed GitHub run, cancelled, all receipts green -> 77"
drive lint-completed-cancelled-green completed-cancelled-green lint gh
expect lint-completed-cancelled-green 77 \
  'receipts: verified' \
  'GitHub run 123 finished cancelled with verified receipts; failing closed' \
  '!running on PC01' \
  '!GitLab'

echo "== scenario 5: queue-timeout fallback reaches a GitLab monitoring fault -> 77"
drive lint-gitlab-monitoring-fault gitlab-status-fault lint both
expect lint-gitlab-monitoring-fault 77 \
  'GitHub unavailable; trying GitLab' \
  'GitLab pipeline 456 in sean.morden1993/firstmate-ci' \
  'GitLab pipeline 456 status unavailable; failing closed' \
  '!running on PC01' \
  '!linter found issues'

echo "== scenario 6: a hosted lint receipt that fails is still a verdict (exit 1)"
drive lint-receipt-failure receipt-failure lint gh
expect lint-receipt-failure 1 \
  'Hosted partition failed: lint-1' \
  '!running on PC01' \
  '!failing closed'

echo "== scenario 7: --help exit contract served by the CLI"
( cd "$REPO" && "$ROUTER" --help ) > "$LOGS/help.log" 2>&1
printf '0\n' > "$LOGS/help.exit"
expect help 0 \
  'Exit: 0 proven success; 1 failed hosted evidence or a failed hosted receipt;' \
  '77 indeterminate hosted outcome that is never a test or lint' \
  'GitLab authentication, project reads, dispatch rejection,' \
  'An accepted GitHub dispatch' \
  'that stays undiscovered fails closed rather than being duplicated.'

echo
column -t -s $'\t' "$results"
