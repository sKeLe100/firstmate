#!/usr/bin/env bash
# Suite body for tests/fm-test-run.test.sh: scheduler lanes, concurrency and
# timing budgets, fail-fast, and load-sensitive retry. Sourced by the wrapper
# after the selection body, so the later fm_run_timed definition still wins as
# it did when both bodies lived in one file. Function definitions only.
test_jobs_requires_proven_isolated() {
  local RUNNER="$FIXTURE_RUNNER"
  local tmp rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --lane portable-serial >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with portable-serial must refuse (exit 2), got $rc"
  grep -Fq 'portable serial lanes stay serial' "$tmp/err" \
    || fail "--jobs refusal message missing: $(cat "$tmp/err")"
  set +e
  "$RUNNER" --jobs 2 tests/fm-fixture.test.sh >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs on a family with no recorded proof must refuse, got $rc"
  # Sharding across runners never relaxes the serial rule inside one shard.
  set +e
  "$RUNNER" --jobs 2 --lane portable-serial-1of11 >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with a portable serial shard must refuse, got $rc"
  grep -Fq 'portable serial lanes stay serial' "$tmp/err3" \
    || fail "shard --jobs refusal message missing: $(cat "$tmp/err3")"
  rm -rf "$tmp"
  pass "--jobs refuses non-proven / stateful selections"
}

# Copy the production runner but supply tiny executable subjects. Their names
# retain the real family admission and weight policy; their bodies exercise
# scheduling without recursively running unrelated subsystem suites.
init_scheduler_fixture_repo() {
  local repo=$1 script
  shift
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/"
  for script in "$@"; do
    printf '#!/usr/bin/env bash\necho "ok - scheduler fixture"\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
}

# Exercise real lane policy on a small inventory; full-repository coverage is
# independently required by COVERAGE_REPORT below.
init_lane_fixture_repo() {
  local repo=$1 script
  local -a scripts=()
  while IFS= read -r script; do
    scripts+=("${script##*/}")
  done < <("$RUNNER" --list --proven-isolated)
  scripts+=(
    fm-watch-triage.test.sh fm-watch-triage-waits.test.sh
    fm-session-lock-ancestry.test.sh fm-task-inbox.test.sh fm-daemon.test.sh
    fm-watch-arm.test.sh fm-wake-queue.test.sh fm-watcher-lock.test.sh
    fm-watch-checkpoint.test.sh fm-inactive-reconcile.test.sh
    fm-mail.test.sh fm-mail-check.test.sh fm-tool-update-check.test.sh
    fm-turnend-guard.test.sh fm-wake-drain-unread-status.test.sh
    fm-wake-pair-dedup.test.sh fm-wake-daemon-lifecycle-e2e.test.sh
    fm-parent-channel-scan-exclusion.test.sh fm-guard-stale-banner.test.sh
    fm-cursor-primary.test.sh fm-backend-herdr-smoke.test.sh
  )
  init_scheduler_fixture_repo "$repo" "${scripts[@]}"
}

test_jobs_admits_a_concurrent_safe_family() {
  local tmp repo runner rc external script
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-admit.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  init_scheduler_fixture_repo "$repo" \
    fm-supervision-events.test.sh fm-session-lock-ancestry.test.sh
  # A rendezvous makes real overlap necessary for success, independently of
  # marker order or the speed of either process on a loaded host.
  for script in fm-supervision-events.test.sh fm-session-lock-ancestry.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
name=${0##*/}
: >"$RENDEZVOUS/$name"
for ((i=0; i<100; i++)); do
  if [ -f "$RENDEZVOUS/fm-supervision-events.test.sh" ] && \
     [ -f "$RENDEZVOUS/fm-session-lock-ancestry.test.sh" ]; then
    echo "ok - concurrent scheduler rendezvous"
    exit 0
  fi
  sleep 0.1
done
echo "not ok - peer never ran concurrently"
exit 1
SH
  done
  set +e
  RENDEZVOUS="$tmp" "$runner" --jobs 2 \
    tests/fm-supervision-events.test.sh tests/fm-session-lock-ancestry.test.sh \
    >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "--jobs on a proven family must be admitted, got $rc: $(cat "$tmp/err") $(cat "$tmp/out")"
  grep -Fq 'FM_TEST_SUMMARY total=2 failed=0' "$tmp/out" \
    || fail "the admitted concurrent run did not report both scripts green: $(cat "$tmp/out")"

  set +e
  "$runner" --jobs 5 tests/fm-session-lock-ancestry.test.sh \
    >"$tmp/over-cap.out" 2>"$tmp/over-cap.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a family run above its proven four-worker cap must be refused, got $rc"

  external="$tmp/fm-session-lock-ancestry.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - colliding external fixture"\n' >"$external"
  chmod +x "$external"
  set +e
  "$runner" --jobs 2 "$external" >"$tmp/external.out" 2>"$tmp/external.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "an external script colliding with a proven family member must be refused, got $rc"
  rm -rf "$tmp"
  pass "--jobs admits and schedules a family with a recorded concurrent proof"
}

# The residual `standalone` family carries a concurrent proof, but the `*)`
# catch-all it was split out of must not: a test nobody has classified yet is
# exactly the one with no proof, so it has to stay serial rather than inherit
# concurrency from the family map's default arm.
test_unmapped_new_test_never_inherits_family_concurrency() {
  local tmp repo rc script
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-unmapped.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh"
  # Two members of the proven residual family, plus a test basename the family
  # map has never seen - the shape of any test added tomorrow.
  for script in fm-procevent.test.sh fm-quota-choose.test.sh fm-zz-unmapped-fixture.test.sh; do
    printf '#!/usr/bin/env bash\necho "ok - %s fixture"\n' "$script" >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done

  set +e
  (cd "$repo" && bin/fm-test-run.sh --jobs 2 \
    tests/fm-procevent.test.sh tests/fm-quota-choose.test.sh) \
    >"$tmp/family.out" 2>"$tmp/family.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "two members of the proven residual family must be admitted, got $rc: $(cat "$tmp/family.err")"
  grep -Fq 'FM_TEST_SUMMARY total=2 failed=0' "$tmp/family.out" \
    || fail "the admitted residual-family run did not report both scripts green: $(cat "$tmp/family.out")"

  set +e
  (cd "$repo" && bin/fm-test-run.sh --jobs 2 \
    tests/fm-procevent.test.sh tests/fm-zz-unmapped-fixture.test.sh) \
    >"$tmp/unmapped.out" 2>"$tmp/unmapped.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "an unclassified new test must not be admitted under --jobs, got $rc: $(cat "$tmp/unmapped.out")"
  grep -Fq 'fm-zz-unmapped-fixture.test.sh' "$tmp/unmapped.err" \
    || fail "the refusal did not name the unclassified script: $(cat "$tmp/unmapped.err")"

  # It is only concurrency that is refused: the same script still runs serially.
  set +e
  (cd "$repo" && bin/fm-test-run.sh tests/fm-zz-unmapped-fixture.test.sh) \
    >"$tmp/serial.out" 2>"$tmp/serial.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "an unclassified test must still run serially, got $rc: $(cat "$tmp/serial.err")"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$tmp/serial.out" \
    || fail "the unmapped fixture did not land in the catch-all family: $(cat "$tmp/serial.out")"
  rm -rf "$tmp"
  pass "an unclassified new test stays serial while the proven residual family runs concurrently"
}

test_quarantine_list_change_selects_runner_contract() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-quarantine-map.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  # The owner item that lands a fix removes its quarantine entry; that edit
  # must select the runner contract rather than refuse as an unmapped path.
  printf '# quarantine\n' >"$repo/tests/fm-test-quarantine.tsv"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) \
    || fail "a quarantine list change must not refuse --changed selection"
  assert_contains "$listed" "tests/fm-test-run.test.sh" \
    "quarantine list change selects the runner contract"
  rm -rf "$tmp"
  pass "quarantine list change selects runner coverage"
}

test_changed_shared_fixture_selects_its_readers() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fixture.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/shared-probe-fixture.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" \
    "shared test fixture selects its pr-forge reader"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" \
    "shared test fixture selects its secondmate reader"
  case "$listed" in
    *fm-backend-orca.test.sh*)
      fail "shared test fixture selection widened past its readers: $listed" ;;
  esac
  git -C "$repo" add tests/shared-probe-fixture.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture-change

  printf '\n' >>"$repo/tests/unread-thing.sh"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "an unread tests/ path must still fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: tests/unread-thing.sh' "$tmp/err" \
    || fail "the refusal did not name the unread tests/ path: $(cat "$tmp/err")"
  git -C "$repo" checkout -q -- tests/unread-thing.sh

  # A nested tests/fixtures/<dir>/<name>-fixture.sh still reaches the
  # directory-scan arm rather than the top-level fixture arm's basename scan.
  printf '\n' >>"$repo/tests/fixtures/demo/demo-fixture.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-orca.test.sh" \
    "a nested fixture selects the suite that reads its directory"

  rm -rf "$tmp"
  pass "a changed shared test fixture selects its readers while an unread tests/ path still refuses"
}

# Workers are handed scripts in order, so the slowest script must start first or
# it runs alone at the tail and throws away most of the concurrency.
test_concurrent_runs_are_ordered_longest_first() {
  local tmp repo runner first rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-order.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  init_scheduler_fixture_repo "$repo" \
    fm-session-lock-ancestry.test.sh fm-task-inbox.test.sh
  # Run the scheduler with deliberately reversed inputs and unequal real hints.
  set +e
  "$runner" --jobs 2 \
    tests/fm-session-lock-ancestry.test.sh tests/fm-task-inbox.test.sh \
    >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "ordered fixture run failed: $(cat "$tmp/err") $(cat "$tmp/out")"
  first=$(grep -m1 '^FM_TEST_BEGIN' "$tmp/out" | awk '{print $3}')
  [ "$first" = tests/fm-task-inbox.test.sh ] \
    || fail "concurrent run did not start the longest script first, started: $first"
  grep -Fq 'FM_TEST_SUMMARY total=2 failed=0' "$tmp/out" \
    || fail "ordered run did not complete both fixture scripts: $(cat "$tmp/out")"
  rm -rf "$tmp"
  pass "a concurrent run starts the longest-hint script first"
}

# --max-wall-ms is checked after the run, so it cannot end a run that never
# finishes. A hung script has to become a bounded failure, because an unbounded
# suite is exactly what silently outruns its caller's invocation budget.
test_per_script_timeout_bounds_a_hang() {
  local tmp repo runner hang rc began ended grandchild_pid grandchild waited
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-hang.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  hang=tests/fm-hang-fixture.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  grandchild_pid="$tmp/grandchild.pid"
  cat >"$repo/$hang" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture is about to hang"
sh -c 'trap "" TERM; echo $$ >"$1"; sleep 600' _ "$GRANDCHILD_PID" &
sleep 600
SH
  chmod +x "$runner" "$repo/$hang"

  began=$(date +%s)
  set +e
  GRANDCHILD_PID="$grandchild_pid" \
    "$runner" --per-script-timeout-secs 3 "$hang" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  ended=$(date +%s)

  [ "$rc" -ne 0 ] || fail "a terminated script must fail the run: $(cat "$tmp/out")"
  [ "$((ended - began))" -lt 120 ] \
    || fail "the per-script bound did not stop a 600s hang (took $((ended - began))s)"
  grep -Fq 'exceeded the per-script bound' "$tmp/out" \
    || fail "the terminated script was not named: $(cat "$tmp/out")"
  grep -Eq 'FM_TEST_END .* exit=124 ' "$tmp/out" \
    || fail "a terminated script must be recorded as exit 124: $(cat "$tmp/out")"
  # The run still completes and accounts for the script, rather than dying.
  grep -Fq 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out" \
    || fail "the bounded run did not report a complete summary: $(cat "$tmp/out")"
  [ -s "$grandchild_pid" ] || fail "the hanging fixture did not record its grandchild"
  grandchild=$(cat "$grandchild_pid")
  waited=0
  while kill -0 "$grandchild" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$grandchild" 2>/dev/null; then
    kill -KILL "$grandchild" 2>/dev/null || true
    fail "the timed-out script left grandchild $grandchild running"
  fi

  # 0 keeps the historical unbounded behavior, so no existing caller changes.
  set +e
  "$runner" --per-script-timeout-secs nope "$hang" >"$tmp/o2" 2>"$tmp/e2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--per-script-timeout-secs with a non-number must be refused, got $rc"

  rm -rf "$tmp"
  pass "--per-script-timeout-secs turns a hung script into a bounded failure"
}

# A ci.yml literal that a hint-table refresh can forget is exactly how the
# 600s per-script bound lost its margin against fm-watch-triage (2026-09-14
# red main). A portable-serial lane must derive its own hang tripwire from the
# hint table instead, at PORTABLE_SERIAL_TIMEOUT_MULTIPLIER times the slowest
# hint, and an explicit --per-script-timeout-secs must still override it.
test_portable_serial_lane_derives_per_script_timeout_from_hints() {
  local tmp repo runner hang rc began ended
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-lane-timeout.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  hang=tests/fm-hang-fixture.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$runner"
  cat >"$repo/$hang" <<'SH'
#!/usr/bin/env bash
sleep 3
echo "ok - fixture slept 3s"
SH
  chmod +x "$repo/$hang"

  # Replace the embedded hint table with one small, controlled entry so the
  # derived bound is fast to observe: this isolated copy's own portable-serial
  # lane contains only the fixture above, so a real repo's much larger hints
  # never leak into the arithmetic under test.
  python3 - "$runner" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
marker = "portable_serial_weight_hints() {\n  cat <<'EOF'\n"
start = text.index(marker) + len(marker)
end = text.index("\nEOF\n", start)
text = text[:start] + "tests/fm-hang-fixture.test.sh 200" + text[end:]
open(path, "w", encoding="utf-8").write(text)
PY
  grep -Fq 'tests/fm-hang-fixture.test.sh 200' "$runner" \
    || fail "hint-table fixture splice did not land: $(cat "$runner")"

  # No --per-script-timeout-secs: the lane must derive 2 * 200ms = 400ms,
  # rounded up to 1s, and kill the 3s sleep well before it would finish.
  began=$(date +%s)
  set +e
  (cd "$repo" && bin/fm-test-run.sh --lane portable-serial) >"$tmp/auto.out" 2>"$tmp/auto.err"
  rc=$?
  set -e
  ended=$(date +%s)
  [ "$rc" -ne 0 ] || fail "the derived bound did not fail the hung script: $(cat "$tmp/auto.out")"
  [ "$((ended - began))" -lt 3 ] \
    || fail "the derived 1s bound did not stop the 3s hang in time (took $((ended - began))s)"
  grep -Fq 'exceeded the per-script bound' "$tmp/auto.out" \
    || fail "the auto-derived timeout did not report a bound failure: $(cat "$tmp/auto.out")"

  # An explicit --per-script-timeout-secs overrides the derived default: the
  # same 3s hang must now complete rather than being killed at ~1s.
  set +e
  (cd "$repo" && bin/fm-test-run.sh --lane portable-serial --per-script-timeout-secs 15) \
    >"$tmp/override.out" 2>"$tmp/override.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "an explicit --per-script-timeout-secs did not override the lane default: $(cat "$tmp/override.out") $(cat "$tmp/override.err")"
  grep -Fq 'FM_TEST_SUMMARY total=1 failed=0' "$tmp/override.out" \
    || fail "the overridden run did not complete the fixture: $(cat "$tmp/override.out")"

  rm -rf "$tmp"
  pass "a portable-serial lane derives its per-script timeout from the hint table, and an explicit flag still overrides it"
}

# --check-coverage only proves the shard partition is complete and disjoint;
# it does not prove a present hint is still an honest number. --check-hint-drift
# is the guard that catches a hint gone stale against what a green run actually
# measured (the fm-watch-triage/fm-teardown drift that produced the 2026-09-14
# red main), but only once the same script drifts on two consecutive runs -
# a lone noisy run only warns, so shared-runner noise on one run can't turn
# into a false red by itself.
test_check_hint_drift_flags_stale_hint() {
  local tmp script hint floor_ms clean_json drift_json drift2_json history rc out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-hintdrift.XXXXXX")
  script=tests/fm-gitignore-config.test.sh
  hint=$(sed -n "s#^${script} \\([0-9][0-9]*\\)\$#\\1#p" "$RUNNER")
  [ -n "$hint" ] || fail "could not read the current hint for $script from $RUNNER"
  floor_ms=$(sed -n 's/^PORTABLE_SERIAL_HINT_DRIFT_FLOOR_MS=\([0-9][0-9]*\)$/\1/p' "$RUNNER")
  [ -n "$floor_ms" ] || fail "could not read PORTABLE_SERIAL_HINT_DRIFT_FLOOR_MS from $RUNNER"
  history="$tmp/history.json"

  # Exactly at the hint: no drift.
  clean_json="$tmp/clean.json"
  cat >"$clean_json" <<JSON
{"scripts": [{"path": "$script", "duration_ms": $hint}]}
JSON
  out=$("$RUNNER" --check-hint-drift --hint-drift-history "$history" "$clean_json") \
    || fail "a measured duration at the hint must not be flagged as drift: $out"
  assert_contains "$out" "FM_TEST_HINT_DRIFT ok" "clean run must report ok"
  assert_contains "$out" "confirmed=0" "clean run must report zero confirmed drift"

  # A measured duration reported by two lane runs: the check takes the
  # slowest of the two, mirroring the "slowest of several green runs" honesty
  # rule the hint table itself is built on. This is the first run to see this
  # drift, so it must only warn, not refuse.
  drift_json="$tmp/drift1.json"
  cat >"$drift_json" <<JSON
{"scripts": [{"path": "$script", "duration_ms": $((hint + floor_ms + 1))}]}
JSON
  # Comfortably larger than drift_json above even after the floor's absolute
  # offset, so it remains the slowest of the two regardless of the floor
  # value: a plain hint*3 stopped being reliably the larger figure once
  # drift_json itself had to add floor_ms to clear the floor on a small hint.
  drift2_json="$tmp/drift2.json"
  cat >"$drift2_json" <<JSON
{"scripts": [{"path": "$script", "duration_ms": $((hint + floor_ms * 2))}]}
JSON
  out=$("$RUNNER" --check-hint-drift --hint-drift-history "$history" "$drift_json" "$drift2_json" 2>&1) \
    || fail "a single-run drift spike must not refuse the check: $out"
  assert_contains "$out" "$script" "the warning must name the drifting script"
  assert_contains "$out" "measured=$((hint + floor_ms * 2))ms" "the warning must show the slowest measured duration across inputs"
  assert_contains "$out" "confirmed=0" "a first-time drift must not be confirmed"

  # Same script drifts again on the next run (history now records the first
  # drift): this is the second consecutive occurrence, so it must refuse.
  set +e
  out=$("$RUNNER" --check-hint-drift --hint-drift-history "$history" "$drift2_json" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a script that drifts on two consecutive runs must refuse: $out"
  assert_contains "$out" "$script" "the drift report must name the stale script"
  assert_contains "$out" "hint=${hint}ms" "the drift report must show the recorded hint"
  assert_contains "$out" "measured=$((hint + floor_ms * 2))ms" "the drift report must show the slowest measured duration across inputs"
  assert_contains "$out" "two consecutive runs" "the drift report must explain why this run refuses"

  # A clean run afterward resets the history, so a one-off spike followed by
  # recovery never haunts a later run.
  out=$("$RUNNER" --check-hint-drift --hint-drift-history "$history" "$clean_json") \
    || fail "a clean run after a refused one must pass: $out"
  out=$("$RUNNER" --check-hint-drift --hint-drift-history "$history" "$drift_json" "$drift2_json" 2>&1) \
    || fail "drift right after a clean run must only warn again, not refuse: $out"

  rm -rf "$tmp"
  pass "--check-hint-drift only refuses a hint that drifts on two consecutive runs, and warns on a single-run spike"
}

# A sub-floor swing on a very short script can cross the 1.5x ratio purely
# from scheduler noise; PORTABLE_SERIAL_HINT_DRIFT_FLOOR_MS keeps the ratio
# meaningful only once the absolute excess is worth caring about.
test_check_hint_drift_ignores_sub_floor_swings() {
  local tmp script hint floor_ms under_json over_json history out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-hintdrift-floor.XXXXXX")
  script=tests/fm-backend-zellij-smoke.test.sh
  hint=$(sed -n "s#^${script} \\([0-9][0-9]*\\)\$#\\1#p" "$RUNNER")
  [ -n "$hint" ] || fail "could not read the current hint for $script from $RUNNER"
  floor_ms=$(sed -n 's/^PORTABLE_SERIAL_HINT_DRIFT_FLOOR_MS=\([0-9][0-9]*\)$/\1/p' "$RUNNER")
  [ -n "$floor_ms" ] || fail "could not read PORTABLE_SERIAL_HINT_DRIFT_FLOOR_MS from $RUNNER"
  history="$tmp/history.json"

  # Past the 1.5x ratio but under the absolute floor: must not be flagged at all.
  under_json="$tmp/under.json"
  cat >"$under_json" <<JSON
{"scripts": [{"path": "$script", "duration_ms": $((hint * 2))}]}
JSON
  out=$("$RUNNER" --check-hint-drift --hint-drift-history "$history" "$under_json") \
    || fail "a sub-floor ratio swing must not be flagged: $out"
  assert_contains "$out" "FM_TEST_HINT_DRIFT ok" "sub-floor swing must report ok"
  assert_contains "$out" "confirmed=0" "sub-floor swing must not be confirmed"
  assert_contains "$out" "warned=0" "sub-floor swing must not even warn"

  # Past both the ratio and the floor: must warn as ordinary first-time drift.
  over_json="$tmp/over.json"
  cat >"$over_json" <<JSON
{"scripts": [{"path": "$script", "duration_ms": $((hint + floor_ms + 1))}]}
JSON
  out=$("$RUNNER" --check-hint-drift --hint-drift-history "$history" "$over_json" 2>&1) \
    || fail "a past-floor ratio swing must warn, not refuse: $out"
  assert_contains "$out" "$script" "a past-floor swing must be named as drift"

  rm -rf "$tmp"
  pass "--check-hint-drift ignores a ratio-only swing under PORTABLE_SERIAL_HINT_DRIFT_FLOOR_MS"
}

# The duration regression this guard exists for: a suite whose scripts are all
# green but whose wall clock outgrew its caller's invocation budget. The caller
# gets killed mid-run and retries invisibly, so an over-budget run has to be a
# failure, not a note in the log.
# tests/fm-watch-triage.test.sh finishes in about 434s alone and about 698s
# under CI load, so the automatic --changed bound must leave a slow but healthy
# watcher-wake-lock script room while still bounding a genuinely hung one
# (upstream issue #3869). The stub records the bound the runner hands it.
test_changed_bound_gives_slow_watcher_suites_headroom() {
  local tmp repo script bound rc
  tmp=$(mktemp -d)
  repo="$tmp/repo"
  script=tests/fm-watch-triage.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cat >"$repo/bin/fm-timeout-lib.sh" <<'SH'
fm_run_timed() {
  printf '%s\n' "$1" >bound-secs
  shift
  "$@"
}
SH
  cat >"$repo/$script" <<'SH'
#!/usr/bin/env bash
echo "ok - healthy but slow watcher suite"
SH
  chmod +x "$repo/bin/fm-test-run.sh" "$repo/$script"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  printf '\n' >>"$repo/$script"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "healthy changed watcher script must pass, got $rc: $(cat "$tmp/out" "$tmp/err")"
  [ -s "$repo/bound-secs" ] || fail "changed watcher script did not run under the automatic bound: $(cat "$tmp/out")"
  bound=$(cat "$repo/bound-secs")
  [ "$bound" -ge 1500 ] \
    || fail "automatic --changed bound for $script must be at least 1500s, got ${bound}s"
  rm -rf "$tmp"
  pass "the automatic --changed bound gives the slow watcher suite at least 1500s"
}

test_max_wall_ms_is_a_result_not_advice() {
  local tmp repo runner fast rc summary_duration budget_duration
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-budget.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  fast=tests/fm-budget-fixture.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cat >"$repo/$fast" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - budget fixture"
SH
  chmod +x "$runner" "$repo/$fast"

  # Comfortably inside budget: the run passes and states the budget it met.
  set +e
  "$runner" --max-wall-ms 60000 "$fast" >"$tmp/under" 2>"$tmp/under.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a run inside its budget must pass, got $rc: $(cat "$tmp/under.err")"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=60000 duration_ms=[0-9]+$' "$tmp/under" \
    || fail "an inside-budget run did not report the budget: $(cat "$tmp/under")"

  # Same green script, budget it cannot meet: the run must FAIL.
  set +e
  "$runner" --max-wall-ms 500 "$fast" >"$tmp/over" 2>"$tmp/over.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an over-budget run must fail through the result path, got $rc"
  grep -Eq '^FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=[0-9]+$' "$tmp/over" \
    || fail "an over-budget run omitted its summary: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_SUMMARY_FAMILY .+$' "$tmp/over" \
    || fail "an over-budget run omitted its family summary: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_SLOWEST rank=1 .+$' "$tmp/over" \
    || fail "an over-budget run omitted its slowest result: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=500 duration_ms=[0-9]+$' "$tmp/over" \
    || fail "an over-budget run omitted its budget result: $(cat "$tmp/over")"
  summary_duration=$(awk '/^FM_TEST_SUMMARY / { for (i=1;i<=NF;i++) if ($i ~ /^duration_ms=/) { sub(/^duration_ms=/, "", $i); print $i } }' "$tmp/over")
  budget_duration=$(awk '/^FM_TEST_BUDGET / { for (i=1;i<=NF;i++) if ($i ~ /^duration_ms=/) { sub(/^duration_ms=/, "", $i); print $i } }' "$tmp/over")
  [ "$budget_duration" = "$summary_duration" ] \
    || fail "budget verdict used a different duration than the summary: $(cat "$tmp/over")"

  # A malformed budget is refused rather than silently ignored.
  set +e
  "$runner" --max-wall-ms 0 "$fast" >"$tmp/bad" 2>"$tmp/bad.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--max-wall-ms 0 must be refused (exit 2), got $rc"
  set +e
  "$runner" --max-wall-ms nope "$fast" >"$tmp/bad2" 2>"$tmp/bad2.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--max-wall-ms with a non-number must be refused (exit 2), got $rc"

  rm -rf "$tmp"
  pass "--max-wall-ms fails an over-budget run and refuses a malformed budget"
}

test_jobs_parallel_scheduler_and_failure_propagation() {
  local tmp repo runner evidence fake_bin a b c d rc begin_n end_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-sched.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  c=tests/fm-lint.test.sh
  d=tests/fm-supervision-instructions.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$runner"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  # The slow fixture blocks on the replacement fixture's own signal rather than
  # a wall-clock sleep, so a loaded machine cannot let it finish first and turn
  # a correct scheduler into a failure. The bounded deadline is only there so a
  # scheduler that really does wait for the oldest worker still reports instead
  # of hanging.
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
if [ -n "${SCHED_WAIT_FOR_REPLACEMENT:-}" ]; then
  waited=0
  while [ ! -e "$SCHED_EVIDENCE/replacement-started" ] && [ "$waited" -lt 600 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
fi
touch "$SCHED_EVIDENCE/slow-done"
echo "ok - slow fixture"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "ok - fast fixture"
SH
  cat >"$repo/$c" <<'SH'
#!/usr/bin/env bash
# Read the evidence before releasing the slow fixture, so the release can never
# race ahead of the check it is being used to make.
if [ -e "$SCHED_EVIDENCE/slow-done" ]; then
  touch "$SCHED_EVIDENCE/replacement-started"
  echo "not ok - scheduler waited for oldest worker"
  exit 1
fi
touch "$SCHED_EVIDENCE/replacement-started"
echo "ok - replacement fixture started before slow fixture finished"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  PATH="$fake_bin:$PATH" SCHED_EVIDENCE="$evidence" SCHED_WAIT_FOR_REPLACEMENT=1 \
    "$runner" --jobs 2 --json "$tmp/timing.json" \
    "$a" "$b" "$c" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "jobs=2 must refill the first completed slot"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$tmp/out" || true)
  [ "$begin_n" -eq 3 ] || fail "expected 3 BEGIN markers, got $begin_n"
  [ "$end_n" -eq 3 ] || fail "expected 3 END markers, got $end_n"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || fail "summary missing for jobs run: $(grep FM_TEST_SUMMARY "$tmp/out")"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==0
assert "jobs=2" in doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "jobs JSON artifact wrong"; }

  # Non-proven path is refused before any worker starts (no race masking).
  cat >"$tmp/fail.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate fail"
exit 1
SH
  chmod +x "$tmp/fail.test.sh"
  set +e
  "$runner" --jobs 2 "$a" "$tmp/fail.test.sh" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "jobs with non-proven fail fixture must refuse before run, got $rc"

  # Parallel failure propagation stays inside the private runner fixture.
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate proven-set fail"
exit 1
SH
  chmod +x "$repo/$b"
  set +e
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "jobs aggregate must be non-zero when a proven worker fails"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out4" \
    || { rm -rf "$tmp"; fail "jobs failure summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out4")"; }

  cat >"$repo/$d" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found" >&2
exit 0
SH
  chmod +x "$repo/$d"
  set +e
  "$runner" --jobs 2 --fail-on-gate-skip 'herdr not found' "$d" >"$tmp/out5" 2>"$tmp/err5"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "parallel stderr gate skip must hard-fail"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out5" \
    || { rm -rf "$tmp"; fail "parallel stderr hard-fail summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out5")"; }

  "$runner" --jobs 2 "$d" >"$tmp/out6" 2>"$tmp/err6" \
    || { rm -rf "$tmp"; fail "ordinary parallel stderr gate skip must remain successful"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates; non-proven refused"
}

test_herdr_ci_family_run_has_a_step_timeout() {
  # The required Herdr lane's hang tripwire is the family-run *step* bound, not
  # the 75-minute job cap. Parse the workflow as YAML so nested `with.name`
  # artifact keys cannot masquerade as the step contract.
  if ! command -v ruby >/dev/null 2>&1; then
    echo "skip: ruby not found (required to parse .github/workflows/ci.yml as YAML)"
    return 0
  fi
  local json job_timeout step_timeout
  json=$(ruby -ryaml -rjson -e '
doc = YAML.load_file(ARGV[0])
job = doc.fetch("jobs").fetch("tests-herdr")
step = job.fetch("steps").find { |s|
  s.is_a?(Hash) && s["name"] == "Run real-Herdr family (serial, required)"
}
raise "missing family-run step" if step.nil?
raise "family-run step has no timeout-minutes" unless step.key?("timeout-minutes")
puts JSON.generate(
  "job_timeout" => job.fetch("timeout-minutes"),
  "step_timeout" => step.fetch("timeout-minutes")
)
' "$ROOT/.github/workflows/ci.yml") \
    || fail "could not parse tests-herdr timeouts from ci.yml"
  job_timeout=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_timeout"])' <<<"$json") \
    || fail "could not read job timeout from parsed workflow"
  step_timeout=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["step_timeout"])' <<<"$json") \
    || fail "could not read step timeout from parsed workflow"
  [ "$job_timeout" = 75 ] \
    || fail "tests-herdr job backstop must stay 75 minutes, got $job_timeout"
  [ "$step_timeout" = 20 ] \
    || fail "family-run step timeout must be 20 minutes, got $step_timeout"
  [ "$step_timeout" -lt "$job_timeout" ] \
    || fail "family-run step timeout must be below the job backstop"
  pass "Herdr CI family-run step times out at 20 min under a 75 min job backstop"
}

test_aggregate_json() {
  local tmp a b
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  cat >"$tmp/a.json" <<'JSON'
{
  "run_id": "a",
  "selection": "lane=portable-parallel-1",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:01:00Z",
  "summary": {"total": 1, "failed": 0, "skipped_gate": 0, "duration_ms": 1000},
  "scripts": [{"path": "tests/a.test.sh", "family": "pure-contract-unit", "duration_ms": 1000, "exit": 0, "gate_skip": false}]
}
JSON
  cat >"$tmp/b.json" <<'JSON'
{
  "run_id": "b",
  "selection": "lane=portable-serial",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:02:00Z",
  "summary": {"total": 2, "failed": 1, "skipped_gate": 0, "duration_ms": 2000},
  "scripts": [
    {"path": "tests/b.test.sh", "family": "afk", "duration_ms": 1500, "exit": 1, "gate_skip": false},
    {"path": "tests/c.test.sh", "family": "afk", "duration_ms": 500, "exit": 0, "gate_skip": false}
  ]
}
JSON
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json")
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 total=3 failed=1" "aggregate summary line"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["kind"]=="aggregate"
assert doc["summary"]["lanes"]==2
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==1
assert doc["summary"]["critical_path_duration_ms"]==2000
assert len(doc["scripts"])==3
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

# --fail-fast is opt-in: CI relies on the default continuing through every
# selected script so it sees the complete result set. Exercise both the flag
# and its env var against a two-script selection whose first script fails, and
# assert on the second script's own FM_TEST_BEGIN marker - the runner only
# emits that once it actually starts a script.
test_fail_fast_stops_after_first_failure() {
  local RUNNER="$FIXTURE_RUNNER"
  local tmp fail_f pass_f rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-ff.XXXXXX")
  fail_f="$tmp/afail.test.sh"
  pass_f="$tmp/bpass.test.sh"
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  chmod +x "$fail_f" "$pass_f"

  # Default (off): the second script still runs.
  set +e
  "$RUNNER" "$fail_f" "$pass_f" >"$tmp/default.txt" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "default run must still exit non-zero"; }
  grep -Fq "FM_TEST_BEGIN" "$tmp/default.txt" \
    || { rm -rf "$tmp"; fail "runner emitted no FM_TEST_BEGIN markers at all"; }
  grep -F "FM_TEST_BEGIN" "$tmp/default.txt" | grep -Fq "bpass.test.sh" \
    || { rm -rf "$tmp"; fail "without --fail-fast the second script must still run"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/default.txt" \
    || { rm -rf "$tmp"; fail "default run should report total=2 failed=1"; }

  # --fail-fast: the second script is never started.
  set +e
  "$RUNNER" --fail-fast "$fail_f" "$pass_f" >"$tmp/ff.txt" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "--fail-fast run must exit non-zero"; }
  grep -F "FM_TEST_BEGIN" "$tmp/ff.txt" | grep -Fq "afail.test.sh" \
    || { rm -rf "$tmp"; fail "--fail-fast must still run the first script"; }
  if grep -F "FM_TEST_BEGIN" "$tmp/ff.txt" | grep -Fq "bpass.test.sh"; then
    rm -rf "$tmp"
    fail "--fail-fast must not start the second script after a failure"
  fi

  # FM_TEST_FAIL_FAST is the equivalent env var.
  set +e
  FM_TEST_FAIL_FAST=1 "$RUNNER" "$fail_f" "$pass_f" >"$tmp/env.txt" 2>&1
  set -e
  if grep -F "FM_TEST_BEGIN" "$tmp/env.txt" | grep -Fq "bpass.test.sh"; then
    rm -rf "$tmp"
    fail "FM_TEST_FAIL_FAST=1 must behave like --fail-fast"
  fi

  # A truthy spelling is honored rather than silently behaving as off.
  set +e
  FM_TEST_FAIL_FAST=true "$RUNNER" "$fail_f" "$pass_f" >"$tmp/true.txt" 2>&1
  set -e
  if grep -F "FM_TEST_BEGIN" "$tmp/true.txt" | grep -Fq "bpass.test.sh"; then
    rm -rf "$tmp"
    fail "FM_TEST_FAIL_FAST=true must behave like --fail-fast, not as off"
  fi
  grep -Fq 'integer expression expected' "$tmp/true.txt" \
    && { rm -rf "$tmp"; fail "FM_TEST_FAIL_FAST=true must not emit shell arithmetic errors"; }

  # A falsy spelling keeps the default continue-through behavior.
  set +e
  FM_TEST_FAIL_FAST=false "$RUNNER" "$fail_f" "$pass_f" >"$tmp/false.txt" 2>&1
  set -e
  grep -F "FM_TEST_BEGIN" "$tmp/false.txt" | grep -Fq "bpass.test.sh" \
    || { rm -rf "$tmp"; fail "FM_TEST_FAIL_FAST=false must leave fail-fast off"; }

  # An unparseable value is a hard usage error, not a silent no-op.
  set +e
  FM_TEST_FAIL_FAST=maybe "$RUNNER" "$fail_f" "$pass_f" >"$tmp/bad.txt" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || { rm -rf "$tmp"; fail "FM_TEST_FAIL_FAST=maybe must exit 2, got $rc"; }
  grep -Fq "FM_TEST_FAIL_FAST" "$tmp/bad.txt" \
    || { rm -rf "$tmp"; fail "rejection should name FM_TEST_FAIL_FAST"; }

  rm -rf "$tmp"
  pass "--fail-fast stops after the first failure and is off by default"
}

# The --jobs>1 early-break lives in the scheduler loop and reads FAILED, which
# record_script_result updates in the PARENT shell when a worker is reaped -
# workers themselves run in subshells and cannot affect it. A refactor that
# moved the increment worker-side would make fail-fast a silent no-op under
# --jobs while every serial test still passed, so this drives the parallel
# path specifically.
#
# Scheduling is asserted through the runner's own FM_TEST_BEGIN marker, which
# the parent prints immediately before forking a worker, so its absence means
# the script was never scheduled. With --jobs 2 the first two scripts are
# always in flight before any reap can happen, and the break is evaluated once
# per remaining script, so the exact cut-off point is not pinned - the
# contract is that scheduling stops rather than running the whole selection.
# Every follower blocks until the failing script has published its evidence,
# which keeps the failure the first result available to reap.
# The unproven remainder runs AFTER every concurrent worker, in its own loop.
# Only the automatic --changed scheduler can produce that remainder (an explicit
# --jobs>1 refuses an unproven selection outright), so this drives --changed
# with a mixed selection: two proven-concurrent scripts, one of which fails, and
# one unproven script that must never start once fail-fast is on.
test_fail_fast_skips_the_unproven_serial_tail() {
  local tmp repo rc tail_evidence
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-ff-tail.XXXXXX")
  repo="$tmp/repo"
  tail_evidence="$tmp/tail-ran"
  init_changed_fixture_repo "$repo"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  # shellcheck disable=SC2016  # literal executable fixtures
  printf '#!/usr/bin/env bash\n. "$(dirname "$0")/../bin/shared-probe-lib.sh"\necho "not ok - deliberate failure"\nexit 1\n' \
    >"$repo/tests/fm-daemon.test.sh"
  # shellcheck disable=SC2016  # literal executable fixtures
  printf '#!/usr/bin/env bash\n. "$(dirname "$0")/../bin/shared-probe-lib.sh"\nsleep 0.2\necho "ok - follower"\n' \
    >"$repo/tests/fm-pi-watch-extension.test.sh"
  # Keeps the shared-probe-lib.sh reference so the changed scan still selects
  # this unproven real-herdr-gated script into the serial tail.
  # shellcheck disable=SC2016  # literal fixture text: $FF_TAIL_EVIDENCE must
  # reach the fixture verbatim and expand when that script runs, not here.
  printf '#!/usr/bin/env bash\n# shared-probe-lib.sh\ntouch "$FF_TAIL_EVIDENCE"\necho "ok - tail"\n' \
    >"$repo/tests/fm-backend-herdr-smoke.test.sh"
  chmod +x "$repo"/tests/*.test.sh
  git -C "$repo" add -A
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixtures
  printf '\n' >>"$repo/bin/shared-probe-lib.sh"

  set +e
  (cd "$repo" && FF_TAIL_EVIDENCE="$tail_evidence" \
    bin/fm-test-run.sh --changed --base HEAD --fail-fast) >"$tmp/ff" 2>"$tmp/fferr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || { cat "$tmp/ff" "$tmp/fferr"; rm -rf "$tmp"; fail "--changed --fail-fast run must exit non-zero"; }
  grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' "$tmp/ff" \
    && { cat "$tmp/ff"; rm -rf "$tmp"; fail "--fail-fast started the unproven serial tail after a failure"; }
  [ ! -e "$tail_evidence" ] \
    || { rm -rf "$tmp"; fail "the unproven serial-tail script ran under --fail-fast"; }
  grep -Fq 'fail-fast: not scheduling remaining scripts' "$tmp/fferr" \
    || { cat "$tmp/fferr"; rm -rf "$tmp"; fail "--fail-fast should log why the serial tail was skipped"; }

  # Default off: the same selection runs the unproven tail to completion.
  set +e
  (cd "$repo" && FF_TAIL_EVIDENCE="$tail_evidence" FM_TEST_FAIL_FAST=0 \
    bin/fm-test-run.sh --changed --base HEAD) >"$tmp/all" 2>"$tmp/allerr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "default --changed run must still exit non-zero"; }
  [ -e "$tail_evidence" ] \
    || { cat "$tmp/all" "$tmp/allerr"; rm -rf "$tmp"; fail "without --fail-fast the serial tail must still run"; }

  rm -rf "$tmp"
  pass "--fail-fast stops the unproven serial remainder after a concurrent failure"
}

test_fail_fast_jobs_stops_scheduling() {
  local tmp repo runner evidence fake_bin rc begin_n last s
  local -a proven
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-ff-jobs.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  proven=(
    tests/fm-brief.test.sh
    tests/fm-composer-lib.test.sh
    tests/fm-lint.test.sh
    tests/fm-crew-state.test.sh
    tests/fm-composer-ghost.test.sh
    tests/fm-herdr-lab.test.sh
  )
  last=${proven[$(( ${#proven[@]} - 1 ))]}
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$runner"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  # First script fails and publishes the evidence the followers wait on.
  cat >"$repo/${proven[0]}" <<'SH'
#!/usr/bin/env bash
touch "$FF_EVIDENCE/first-failed"
echo "not ok - deliberate first failure"
exit 1
SH
  for s in "${proven[@]:1}"; do
    cat >"$repo/$s" <<'SH'
#!/usr/bin/env bash
waited=0
while [ ! -e "$FF_EVIDENCE/first-failed" ] && [ "$waited" -lt 600 ]; do
  sleep 0.05
  waited=$((waited + 1))
done
echo "ok - follower"
SH
  done
  chmod +x "$runner" "$fake_bin/stat"
  for s in "${proven[@]}"; do chmod +x "$repo/$s"; done

  # --fail-fast: scheduling stops; the last script is never started.
  set +e
  PATH="$fake_bin:$PATH" FF_EVIDENCE="$evidence" \
    "$runner" --jobs 2 --fail-fast "${proven[@]}" >"$tmp/ff" 2>"$tmp/fferr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || { cat "$tmp/ff" "$tmp/fferr"; rm -rf "$tmp"; fail "--jobs --fail-fast run must exit non-zero"; }
  grep -F 'FM_TEST_BEGIN' "$tmp/ff" | grep -Fq "${proven[0]}" \
    || { cat "$tmp/ff" "$tmp/fferr"; rm -rf "$tmp"; fail "the failing script must still be scheduled"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/ff" || true)
  [ "$begin_n" -lt "${#proven[@]}" ] \
    || { rm -rf "$tmp"; fail "--jobs --fail-fast scheduled all ${#proven[@]} scripts (FAILED not seen by the scheduler)"; }
  if grep -F 'FM_TEST_BEGIN' "$tmp/ff" | grep -Fq "$last"; then
    rm -rf "$tmp"
    fail "--jobs --fail-fast must not schedule $last after a failure"
  fi
  grep -Fq 'fail-fast: not scheduling remaining scripts' "$tmp/fferr" \
    || { rm -rf "$tmp"; fail "--jobs --fail-fast should log why it stopped"; }

  # Default off: every script is scheduled even though the first one failed.
  # FM_TEST_FAIL_FAST is pinned so an ambient value cannot decide the result.
  rm -f "$evidence/first-failed"
  set +e
  PATH="$fake_bin:$PATH" FF_EVIDENCE="$evidence" FM_TEST_FAIL_FAST=0 \
    "$runner" --jobs 2 "${proven[@]}" >"$tmp/all" 2>"$tmp/allerr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "default --jobs run must still exit non-zero"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/all" || true)
  [ "$begin_n" -eq "${#proven[@]}" ] \
    || { cat "$tmp/all" "$tmp/allerr"; rm -rf "$tmp"; fail "without --fail-fast all ${#proven[@]} scripts must run, got $begin_n"; }
  grep -Fq "FM_TEST_SUMMARY total=${#proven[@]} failed=1" "$tmp/all" \
    || { rm -rf "$tmp"; fail "default --jobs summary wrong: $(grep FM_TEST_SUMMARY "$tmp/all")"; }

  rm -rf "$tmp"
  pass "--fail-fast stops the --jobs scheduler after the first failure"
}

test_automatic_eight_jobs_preserves_isolation_phases() {
  local tmp repo script out rc
  local -a proven=() family=(fm-branch-supervision.test.sh fm-busy-adapter-wiring.test.sh
    fm-busy-state.test.sh fm-classify-corr-token.test.sh fm-claude-stop-autoarm.test.sh)
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-eight.XXXXXX")
  repo="$tmp/repo"
  while IFS= read -r script; do
    [ "${#proven[@]}" -lt 8 ] || break
    proven+=("${script##*/}")
  done < <("$RUNNER" --list --proven-isolated)
  init_scheduler_fixture_repo "$repo" "${proven[@]}" "${family[@]}" unproven.test.sh
  mkdir "$repo/started"
  for script in "${proven[@]}"; do
    cat > "$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
touch "started/$(basename "$0")"
for ((i=0; i<300; i++)); do
  [ "$(find started -type f | wc -l)" -eq 8 ] && exit 0
  sleep 0.05
done
echo 'not ok - eight workers did not rendezvous'
exit 1
SH
  done
  for script in "${family[@]}"; do
    printf '#!/usr/bin/env bash\nsleep 0.2\necho "ok - family fixture"\n' > "$repo/tests/$script"
  done
  out="$tmp/out"
  (cd "$repo" && FM_TEST_RUN_AUTO_JOBS_MAX=8 FM_TEST_RUN_CPU_COUNT_OVERRIDE=16 \
    bin/fm-test-run.sh --all) > "$out" 2> "$tmp/err" \
    || { cat "$out" "$tmp/err"; fail "eight-job automatic fixture failed"; }
  python3 - "$out" <<'CHECK' || fail "eight-job isolation phases changed"
import sys
active = set()
peak = 0
completed = 0
for line in open(sys.argv[1]):
    parts = line.split()
    if parts[:1] == ["FM_TEST_BEGIN"]:
        name = parts[2]
        if name.endswith("unproven.test.sh"):
            assert completed == 13, completed
            assert not active, active
        if "family=standalone" in parts:
            assert all(x.startswith("standalone:") for x in active), active
            assert len(active) < 4, active
            key = "standalone:" + name
        else:
            assert not any(x.startswith("standalone:") for x in active), active
            key = name
        active.add(key)
        peak = max(peak, len(active))
    elif parts[:1] == ["FM_TEST_END"]:
        completed += 1
        name = parts[2]
        active.discard(name)
        active.discard("standalone:" + name)
assert peak == 8, peak
assert not active, active
CHECK
  # Explicit numeric concurrency still refuses a mixed unproven selection.
  set +e
  (cd "$repo" && FM_TEST_RUN_AUTO_JOBS_MAX=8 bin/fm-test-run.sh "tests/${proven[0]}" tests/unproven.test.sh --jobs 8) > "$tmp/refused" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "explicit contradictory jobs unexpectedly succeeded"
  grep -q 'not in the proven-isolated set' "$tmp/refused" || fail "explicit refusal semantics changed"
  if FM_TEST_RUN_AUTO_JOBS_MAX=9 "$repo/bin/fm-test-run.sh" --all > "$tmp/invalid" 2>&1; then
    fail "invalid automatic ceiling was accepted"
  fi
  rm -rf "$tmp"
  pass "automatic eight-job phases retain family caps, serial tails and explicit refusals"
}

# P2 (data/ci-pipeline-review-scout/report.md): the automatic --changed/scripts
# scheduler throttles concurrency for host contention and reports its inputs.
test_host_load_marker_and_scheduler_throttle() {
  local tmp repo script
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-host-load.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  for script in fm-backend-herdr-smoke.test.sh fm-daemon.test.sh fm-pi-watch-extension.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/../bin/shared-probe-lib.sh"
echo "ok - host load fixture"
SH
    chmod +x "$repo/tests/$script"
  done
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixtures
  printf '\n' >>"$repo/bin/shared-probe-lib.sh"

  (cd "$repo" && FM_TEST_RUN_CPU_COUNT_OVERRIDE=4 FM_TEST_RUN_LOAD5_OVERRIDE=0.5 \
    bin/fm-test-run.sh --changed --base HEAD) >"$tmp/idle.out" 2>"$tmp/idle.err" \
    || { cat "$tmp/idle.err"; rm -rf "$tmp"; fail "idle host-load fixture run failed"; }
  grep -Fq 'FM_TEST_HOST_LOAD load5=0.5 cpus=4 jobs=4 per_script_timeout_secs=' "$tmp/idle.out" \
    || { cat "$tmp/idle.out"; rm -rf "$tmp"; fail "idle host did not report the full jobs=4 baseline"; }

  (cd "$repo" && FM_TEST_RUN_CPU_COUNT_OVERRIDE=4 FM_TEST_RUN_LOAD5_OVERRIDE=5 \
    bin/fm-test-run.sh --changed --base HEAD) >"$tmp/mild.out" 2>"$tmp/mild.err" \
    || { cat "$tmp/mild.err"; rm -rf "$tmp"; fail "mild-load fixture run failed"; }
  grep -Fq 'FM_TEST_HOST_LOAD load5=5 cpus=4 jobs=2 per_script_timeout_secs=' "$tmp/mild.out" \
    || { cat "$tmp/mild.out"; rm -rf "$tmp"; fail "load5 > cpus did not throttle to 2 workers"; }

  (cd "$repo" && FM_TEST_RUN_CPU_COUNT_OVERRIDE=4 FM_TEST_RUN_LOAD5_OVERRIDE=9 \
    bin/fm-test-run.sh --changed --base HEAD) >"$tmp/heavy.out" 2>"$tmp/heavy.err" \
    || { cat "$tmp/heavy.err"; rm -rf "$tmp"; fail "heavy-load fixture run failed"; }
  grep -Fq 'FM_TEST_HOST_LOAD load5=9 cpus=4 jobs=1 per_script_timeout_secs=' "$tmp/heavy.out" \
    || { cat "$tmp/heavy.out"; rm -rf "$tmp"; fail "load5 > 2x cpus did not throttle to 1 worker"; }

  # An explicit --jobs names its own concurrency and is never throttled or
  # reported by the automatic host-load marker.
  (cd "$repo" && FM_TEST_RUN_CPU_COUNT_OVERRIDE=4 FM_TEST_RUN_LOAD5_OVERRIDE=9 \
    bin/fm-test-run.sh --changed --base HEAD --jobs 1) >"$tmp/explicit.out" 2>"$tmp/explicit.err" \
    || { cat "$tmp/explicit.err"; rm -rf "$tmp"; fail "explicit --jobs 1 fixture run failed"; }
  grep -Fq 'FM_TEST_HOST_LOAD' "$tmp/explicit.out" \
    && { cat "$tmp/explicit.out"; rm -rf "$tmp"; fail "explicit --jobs must skip the host-load marker entirely"; }

  rm -rf "$tmp"
  pass "FM_TEST_HOST_LOAD reports load/cpus/jobs and throttles automatic concurrency, never an explicit --jobs"
}

# P2 item 2: CHANGED_DEFAULT_TIMEOUT_SECS scales by max(1, load5/cpus).
test_changed_default_timeout_scales_with_host_load() {
  local tmp repo
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timeout-scale.XXXXXX")
  repo="$tmp/timeout-repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/bin/fm-timeout-lib.sh" <<'SH'
fm_run_timed() {
  printf '%s\n' "$1" >"$FM_TIMEOUT_SEEN_FILE"
  shift
  "$@"
}
SH
  cat >"$repo/tests/fm-timeout-scale.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - timeout scale fixture"
SH
  chmod +x "$repo/tests/fm-timeout-scale.test.sh"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  printf '\n' >>"$repo/tests/fm-timeout-scale.test.sh"

  (cd "$repo" && FM_TIMEOUT_SEEN_FILE="$tmp/seen-idle" \
    FM_TEST_RUN_CPU_COUNT_OVERRIDE=4 FM_TEST_RUN_LOAD5_OVERRIDE=0 \
    bin/fm-test-run.sh --changed --base HEAD) >"$tmp/idle.out" 2>"$tmp/idle.err" \
    || { cat "$tmp/idle.err"; rm -rf "$tmp"; fail "idle timeout-scale fixture run failed"; }
  [ "$(cat "$tmp/seen-idle")" = 1500 ] \
    || { rm -rf "$tmp"; fail "idle host must keep the 1500s base bound, got $(cat "$tmp/seen-idle")"; }
  grep -Fq 'per_script_timeout_secs=1500' "$tmp/idle.out" \
    || { cat "$tmp/idle.out"; rm -rf "$tmp"; fail "idle host-load marker did not report the base bound"; }

  (cd "$repo" && FM_TIMEOUT_SEEN_FILE="$tmp/seen-loaded" \
    FM_TEST_RUN_CPU_COUNT_OVERRIDE=4 FM_TEST_RUN_LOAD5_OVERRIDE=8 \
    bin/fm-test-run.sh --changed --base HEAD) >"$tmp/loaded.out" 2>"$tmp/loaded.err" \
    || { cat "$tmp/loaded.err"; rm -rf "$tmp"; fail "loaded timeout-scale fixture run failed"; }
  [ "$(cat "$tmp/seen-loaded")" = 3000 ] \
    || { rm -rf "$tmp"; fail "load5=2x cpus must double the bound, got $(cat "$tmp/seen-loaded")"; }
  grep -Fq 'per_script_timeout_secs=3000' "$tmp/loaded.out" \
    || { cat "$tmp/loaded.out"; rm -rf "$tmp"; fail "loaded host-load marker did not report the scaled bound"; }

  rm -rf "$tmp"
  pass "the --changed default per-script timeout scales by max(1, load5/cpus)"
}

# assert_changed_script_gets_own_scaled_timeout <script-stem> <marker-field>:
# on the --changed path <script-stem> retains an explicit load-scaled
# 1500s bound, with ordinary scripts using the same upstream base.
assert_changed_script_gets_own_scaled_timeout() {
  local stem=$1 field=$2 tmp repo s
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-$stem-timeout.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/bin/fm-timeout-lib.sh" <<'SH'
fm_run_timed() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      *.test.sh) printf '%s %s\n' "$(basename "$arg")" "$1" >>"$FM_TIMEOUT_SEEN_FILE" ;;
    esac
  done
  shift
  "$@"
}
SH
  for s in "$stem" fm-wake-queue; do
    printf '#!/usr/bin/env bash\necho "ok - %s fixture"\n' "$s" >"$repo/tests/$s.test.sh"
    chmod +x "$repo/tests/$s.test.sh"
  done
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  printf '\n' >>"$repo/tests/$stem.test.sh"
  printf '\n' >>"$repo/tests/fm-wake-queue.test.sh"

  (cd "$repo" && FM_TIMEOUT_SEEN_FILE="$tmp/seen-idle" \
    FM_TEST_RUN_CPU_COUNT_OVERRIDE=4 FM_TEST_RUN_LOAD5_OVERRIDE=0 \
    bin/fm-test-run.sh --changed --base HEAD) >"$tmp/idle.out" 2>"$tmp/idle.err" \
    || { cat "$tmp/idle.err"; rm -rf "$tmp"; fail "idle $stem timeout fixture run failed"; }
  grep -qx "$stem.test.sh 1500" "$tmp/seen-idle" \
    || { cat "$tmp/seen-idle"; rm -rf "$tmp"; fail "idle host must bound $stem at 1500s"; }
  grep -qx 'fm-wake-queue.test.sh 1500' "$tmp/seen-idle" \
    || { cat "$tmp/seen-idle"; rm -rf "$tmp"; fail "other load-sensitive scripts must keep the 1500s base"; }
  grep -q "^FM_TEST_HOST_LOAD .* per_script_timeout_secs=1500 .*${field}_timeout_secs=1500" "$tmp/idle.out" \
    || { cat "$tmp/idle.out"; rm -rf "$tmp"; fail "idle host-load marker did not report the $field bound"; }

  (cd "$repo" && FM_TIMEOUT_SEEN_FILE="$tmp/seen-loaded" \
    FM_TEST_RUN_CPU_COUNT_OVERRIDE=4 FM_TEST_RUN_LOAD5_OVERRIDE=8 \
    bin/fm-test-run.sh --changed --base HEAD) >"$tmp/loaded.out" 2>"$tmp/loaded.err" \
    || { cat "$tmp/loaded.err"; rm -rf "$tmp"; fail "loaded $stem timeout fixture run failed"; }
  grep -qx "$stem.test.sh 3000" "$tmp/seen-loaded" \
    || { cat "$tmp/seen-loaded"; rm -rf "$tmp"; fail "load5=2x cpus must double the $stem bound"; }

  rm -rf "$tmp"
  pass "the --changed path bounds $stem at its own load-scaled 1500s base"
}

# fm-watch-triage measured 924s under PC01 full-suite load against the 900s base.
test_changed_watch_triage_gets_its_own_scaled_timeout() {
  assert_changed_script_gets_own_scaled_timeout fm-watch-triage watch_triage
}

# fm-captain-hold-lifecycle measured 296s standalone but hit the 900s base
# under PC01 full-suite load.
test_changed_captain_hold_gets_its_own_scaled_timeout() {
  assert_changed_script_gets_own_scaled_timeout fm-captain-hold-lifecycle captain_hold
}

# P2 item 3: the token-free retry re-runs exactly the load-plausible failures
# once, serially, and clears a run whose only failures come from host
# contention rather than a real regression.
test_token_free_retry_recovers_load_sensitive_failure() {
  local tmp repo flag
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-retry-recover.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  flag="$tmp/attempt"
  cat >"$repo/tests/fm-watch-triage.test.sh" <<SH
#!/usr/bin/env bash
n=\$(cat "$flag" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" >"$flag"
if [ "\$n" -lt 2 ]; then
  echo "not ok - simulated load flake attempt \$n"
  exit 1
fi
echo "ok - passed on retry attempt \$n"
SH
  chmod +x "$repo/tests/fm-watch-triage.test.sh"
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture

  (cd "$repo" && FM_TEST_RUN_LOAD_RETRY_WAIT_MAX_SECS=5 FM_TEST_RUN_LOAD_RETRY_POLL_SECS=1 \
    bin/fm-test-run.sh --changed --base HEAD~1) >"$tmp/out" 2>"$tmp/err" \
    || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "token-free retry should recover and exit 0"; }
  grep -Fq 'token-free retry:' "$tmp/err" \
    || { cat "$tmp/err"; rm -rf "$tmp"; fail "retry did not log its wait/re-run"; }
  grep -Fq 'FM_TEST_SUMMARY total=1 failed=0' "$tmp/out" \
    || { cat "$tmp/out"; rm -rf "$tmp"; fail "recovered retry must report a clean summary"; }
  [ "$(grep -c '^FM_TEST_BEGIN' "$tmp/out")" -eq 2 ] \
    || { cat "$tmp/out"; rm -rf "$tmp"; fail "retry must show two begin markers (original + one retry)"; }

  rm -rf "$tmp"
  pass "token-free retry re-runs a load-sensitive failure once and clears it without a real regression"
}

# The retry also admits a plain exit=124 timeout regardless of script name,
# since a hang under host contention is the other half of the declared class.
test_token_free_retry_covers_exit_124_regardless_of_name() {
  local tmp repo flag
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-retry-124.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  flag="$tmp/attempt"
  cat >"$repo/tests/fm-unrelated-name.test.sh" <<SH
#!/usr/bin/env bash
n=\$(cat "$flag" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" >"$flag"
if [ "\$n" -lt 2 ]; then
  sleep 3
fi
echo "ok - fast on attempt \$n"
SH
  chmod +x "$repo/tests/fm-unrelated-name.test.sh"
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture

  (cd "$repo" && FM_TEST_RUN_LOAD_RETRY_WAIT_MAX_SECS=5 FM_TEST_RUN_LOAD_RETRY_POLL_SECS=1 \
    bin/fm-test-run.sh --changed --base HEAD~1 --per-script-timeout-secs 1) >"$tmp/out" 2>"$tmp/err" \
    || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "an exit=124 timeout must still qualify for the token-free retry"; }
  grep -Eq '^FM_TEST_END .+ exit=124 ' "$tmp/out" \
    || { cat "$tmp/out"; rm -rf "$tmp"; fail "expected the first attempt to time out"; }
  grep -Fq 'token-free retry:' "$tmp/err" \
    || { cat "$tmp/err"; rm -rf "$tmp"; fail "exit=124 did not trigger the token-free retry"; }
  grep -Fq 'FM_TEST_SUMMARY total=1 failed=0' "$tmp/out" \
    || { cat "$tmp/out"; rm -rf "$tmp"; fail "recovered exit=124 retry must report a clean summary"; }

  rm -rf "$tmp"
  pass "the token-free retry admits exit=124 regardless of the load-sensitive name list"
}

# The retry must never mask a genuine regression: any failure outside the
# exit=124/load-sensitive class disqualifies the whole run from retrying.
test_token_free_retry_skips_when_a_failure_is_not_load_plausible() {
  local tmp repo rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-retry-skip.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline

  cat >"$repo/tests/fm-watch-triage.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - simulated load flake, never recovers in this test"
exit 1
SH
  cat >"$repo/tests/fm-genuine-bug.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - a real regression"
exit 1
SH
  chmod +x "$repo/tests/fm-watch-triage.test.sh" "$repo/tests/fm-genuine-bug.test.sh"
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture

  set +e
  (cd "$repo" && FM_TEST_RUN_LOAD_RETRY_WAIT_MAX_SECS=5 FM_TEST_RUN_LOAD_RETRY_POLL_SECS=1 \
    bin/fm-test-run.sh --changed --base HEAD~1) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] \
    || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "a run with a non-load-plausible failure must still fail, got $rc"; }
  grep -Fq 'token-free retry:' "$tmp/err" \
    && { cat "$tmp/err"; rm -rf "$tmp"; fail "a genuine failure alongside a load-sensitive one must never retry"; }
  [ "$(grep -c '^FM_TEST_BEGIN' "$tmp/out")" -eq 2 ] \
    || { cat "$tmp/out"; rm -rf "$tmp"; fail "no retry means exactly one begin marker per selected script"; }

  rm -rf "$tmp"
  pass "token-free retry never fires when any failure is outside the load-sensitive/timeout class"
}

test_cleanup_tolerates_read_only_run_dirs() {
  local RUNNER="$FIXTURE_RUNNER"
  local tmp out rc leftover
  tmp=$(fm_test_tmproot fm-test-run-cleanup)
  mkdir -p "$tmp/runtmp"
  # A passing suite that leaves a read-only directory under the runner's own
  # temp root, the shape left by fixtures with read-only *.git-hooks dirs.
  cat >"$tmp/leave-readonly.test.sh" <<'SH'
#!/usr/bin/env bash
for run in "$TMPDIR"/fm-test-run.*/; do
  mkdir -p "$run/ro/inner"
  : >"$run/ro/inner/file"
  chmod a-w "$run/ro/inner" "$run/ro"
done
echo "ok - leaves read-only dir"
SH
  chmod +x "$tmp/leave-readonly.test.sh"
  out=$(TMPDIR="$tmp/runtmp" "$RUNNER" "$tmp/leave-readonly.test.sh" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "cleanup of a read-only run dir changed exit status to $rc: $out"
  assert_contains "$out" 'FM_TEST_SUMMARY total=1 failed=0' "fixture suite did not pass: $out"
  leftover=$(find "$tmp/runtmp" -mindepth 1 -maxdepth 1 -name 'fm-test-run.*' 2>/dev/null)
  [ -z "$leftover" ] || fail "runner temp root was not removed: $leftover"
  pass "a read-only dir left under the run root never changes the aggregate exit status"
}
