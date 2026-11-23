#!/usr/bin/env bash
# Behavior tests for bin/fm-mistakes-review.sh, the 2-day mistakes-review
# cadence helper. The suite drives its public commands against real pass-marker
# state and a stubbed timed-dispatch executable; it never asserts source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-mistakes-review-tests)
CHECK="$ROOT/bin/fm-mistakes-review.sh"

new_home() {  # <name>; prints the home path
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

run() {  # <home> <now> [args...]
  local home=$1 now=$2
  shift 2
  FM_HOME="$home" FM_MISTAKES_REVIEW_NOW="$now" "$CHECK" "$@"
}

stub_dispatch() {  # <dir>; prints the stub path
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/fake-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FAKE_DISPATCH_ARGS:?}"
EOF
  chmod +x "$dir/fake-dispatch.sh"
  printf '%s\n' "$dir/fake-dispatch.sh"
}

test_due_without_a_record_is_due_and_status_says_so() {
  local home out rc
  home=$(new_home fresh)
  out=$(run "$home" 1000 due); rc=$?
  expect_code 0 "$rc" "a review with no completed pass must be due"
  out=$(run "$home" 1000 status)
  assert_contains "$out" "last_pass: none" "status must report no recorded pass"
  assert_contains "$out" "due: yes" "status must report the pass due"
  pass "the review is due until a pass is recorded"
}

test_mark_records_the_pass_and_gates_the_boundary() {
  local home rc
  home=$(new_home marked)
  run "$home" 2000 mark >/dev/null
  assert_grep $'last_pass\t2000' "$home/state/.mistakes-review-last" "mark must record the completed pass"
  run "$home" 2000 due; rc=$?
  expect_code 1 "$rc" "a just-recorded pass must not be due"
  FM_MISTAKES_REVIEW_NOW=$((2000 + 172799)) FM_HOME="$home" "$CHECK" due; rc=$?
  expect_code 1 "$rc" "one second before the 2-day interval must not be due"
  FM_MISTAKES_REVIEW_NOW=$((2000 + 172800)) FM_HOME="$home" "$CHECK" due; rc=$?
  expect_code 0 "$rc" "the exact 2-day boundary must be due"
  pass "mark gates the 2-day interval from the completed pass"
}

test_arm_targets_the_next_pass_through_dispatch() {
  local home stub args target
  home=$(new_home armed)
  stub=$(stub_dispatch "$TMP_ROOT/armed-bin")
  args="$TMP_ROOT/armed-args"
  FAKE_DISPATCH_ARGS="$args" FM_MISTAKES_REVIEW_DISPATCH_BIN="$stub" run "$home" 3000 arm >/dev/null \
    || fail "arm must succeed with a runnable dispatcher"
  target=$((3000 + 172800))
  assert_grep "arm" "$args" "arm must invoke the dispatcher"$'\n'
  assert_grep "mistakes-review" "$args" "arm must name the review task"
  assert_grep "@$target" "$args" "arm must target the default 2-day deadline"
  FAKE_DISPATCH_ARGS="$args" FM_MISTAKES_REVIEW_DISPATCH_BIN="$stub" run "$home" 3000 arm --in 60 >/dev/null \
    || fail "arm --in must succeed"
  assert_grep "@$((3000 + 60))" "$args" "arm --in must honor the requested delay"
  pass "arm schedules the next pass through timed-dispatch"
}

test_arm_refuses_bad_input_and_a_missing_dispatcher() {
  local home rc
  home=$(new_home bad)
  run "$home" 4000 arm --in nope >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a non-numeric --in must be refused"
  FM_MISTAKES_REVIEW_DISPATCH_BIN="$TMP_ROOT/no-such-dispatch" run "$home" 4000 arm >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a missing dispatcher must be refused"
  pass "arm refuses bad input instead of arming nothing"
}

test_due_without_a_record_is_due_and_status_says_so
test_mark_records_the_pass_and_gates_the_boundary
test_arm_targets_the_next_pass_through_dispatch
test_arm_refuses_bad_input_and_a_missing_dispatcher
