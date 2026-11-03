#!/usr/bin/env bash
# fm-control.sh relaunch under config/claude-accounts: a declared account list
# keeps the account a ship or scout records, moves it only on an explicit
# --account, and refuses a bad choice before the running agent stops.
# Split from tests/fm-control-relaunch.test.sh (size ceiling); it reuses that
# file's hermetic helpers by sourcing it library-only.
set -u

FM_RELAUNCH_LIB_ONLY=1
# shellcheck source=tests/fm-control-relaunch.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch.test.sh"

# add_listed_task <case-dir> <id> <recorded-account>: a live Claude ship
# recorded on <recorded-account> in a home declaring two signed-in accounts,
# first and second, plus a signed-out one.
add_listed_task() {
  local dir=$1 id=$2 recorded=$3
  add_ship_task "$dir" "$id" claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/first" "$dir/second" "$dir/signed-out"
  : > "$dir/first/.credentials.json"
  : > "$dir/second/.credentials.json"
  printf '%s\n' "$dir/first" "$dir/second" "$dir/signed-out" > "$dir/home/config/claude-accounts"
  [ -z "$recorded" ] || echo "account=$recorded" >> "$dir/home/state/$id.meta"
}

test_account_list_relaunch_reuses_the_recorded_account() {
  local dir out rc id=rl-list
  dir=$(new_case list-reuse "$id")
  add_listed_task "$dir" "$id" "$dir/first"
  out=$(run_control "$dir" "$id" relaunch --note "same account"); rc=$?
  expect_code 0 "$rc" "a relaunch under a list should reuse the recorded account"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" account)" = "$dir/first" ] || fail "the relaunched record should keep the recorded account"
  assert_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR='$dir/first'" \
    "the replacement should launch under the recorded account"
  : > "$dir/fake/literal"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" "$id" --relaunch); rc=$?
  expect_code 0 "$rc" "a direct fm-spawn --relaunch under a list should reuse the recorded account"$'\n'"$out"
  assert_contains "$out" "account=$dir/first" "the direct relaunch should report the recorded account"
  pass "fm-control relaunch: a declared account list keeps the account the task records"
}

test_account_list_relaunch_moves_only_on_explicit_account() {
  local dir out rc id=rl-list-move
  dir=$(new_case list-move "$id")
  add_listed_task "$dir" "$id" "$dir/first"
  out=$(run_control "$dir" "$id" relaunch --account "$dir/second" --note "first is exhausted"); rc=$?
  expect_code 0 "$rc" "an explicit --account relaunch should move the task"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" account)" = "$dir/second" ] || fail "the relaunched record should name the new account"
  assert_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR='$dir/second'" \
    "the replacement should launch under the explicitly chosen account"
  : > "$dir/fake/literal"
  out=$(run_control "$dir" "$id" relaunch --note "stay"); rc=$?
  expect_code 0 "$rc" "a later plain relaunch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" account)" = "$dir/second" ] || fail "a later relaunch should keep the moved account"
  pass "fm-control relaunch: only an explicit --account moves a task to another declared account"
}

test_account_list_relaunch_refusals_happen_before_stop() {
  local dir out rc id=rl-list-refuse case_name recorded flag needle
  for case_name in undeclared newline signed-out unrecorded removed wrong-harness; do
    dir=$(new_case "list-refuse-$case_name" "$id")
    recorded="$dir/first"
    flag=()
    case "$case_name" in
      undeclared)
        flag=(--account "$dir/elsewhere")
        needle="account '$dir/elsewhere' is not declared in config/claude-accounts" ;;
      newline)
        flag=(--account "$dir/elsewhere"$'\n'"$dir/second")
        needle="--account must name one config/claude-accounts entry exactly, with no control characters" ;;
      signed-out)
        flag=(--account "$dir/signed-out")
        needle="config/claude-accounts pins Claude workers to $dir/signed-out, which is not signed in" ;;
      unrecorded)
        recorded=
        needle="must name one with --account" ;;
      removed)
        recorded="$dir/retired"
        needle="account '$dir/retired' is not declared in config/claude-accounts" ;;
      wrong-harness)
        flag=(--harness pi --account "$dir/second")
        needle="applies to Claude workers only, not pi" ;;
    esac
    add_listed_task "$dir" "$id" "$recorded"
    cp "$dir/home/state/$id.meta" "$dir/meta-before"
    out=$(run_control "$dir" "$id" relaunch ${flag[@]+"${flag[@]}"} --note "refuse $case_name"); rc=$?
    expect_code 1 "$rc" "the $case_name relaunch must refuse"$'\n'"$out"
    assert_contains "$out" "$needle" "the $case_name refusal should say why"
    [ "$(cat "$dir/fake/command")" = claude ] || fail "the $case_name refusal must happen before the running agent stops"
    [ ! -s "$dir/fake/literal" ] || fail "the $case_name refusal must send no lifecycle input"
    cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "the $case_name refusal must leave the task record untouched"
  done
  pass "fm-control relaunch: undeclared, newline-split, signed-out, unrecorded, retired, and wrong-runner accounts refuse before the old agent stops"
}

test_account_list_relaunch_reuses_the_recorded_account
test_account_list_relaunch_moves_only_on_explicit_account
test_account_list_relaunch_refusals_happen_before_stop

echo "# all fm-control-relaunch-account tests passed"
