#!/usr/bin/env bash
# tests/fm-send-cache-stale-guard.test.sh - fm-send's prompt-cache steer guard.
#
# An ordinary local steer is refused when the target's newest activity marker
# (state/<id>.meta, .status, .turn-ended) shows it idle past the prompt-cache
# TTL (docs/configuration.md "Prompt-cache steer guard"). These tests drive
# the real fm-send executable:
#   1. An unreadable idle signal (every stat of the activity markers fails)
#      fails open rather than blocking the steer.
#   2. A task idle under the default TTL is not refused.
#   3. A task idle past the default TTL is refused, prints the relaunch
#      command, and never touches the inbox.
#   4. --steer-stale overrides the refusal and the steer is durably sent.
#   5. config/cache-ttl-seconds overrides the default threshold (reading past
#      blank and comment lines), and a configured 0 disables the guard
#      instead of refusing everything.
#   6. A stale turn-ended marker on a task whose OTHER activity markers are
#      fresh, and a task classified busy (mid-turn), are never refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-cache-stale-guard)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  capture-pane) printf '' ;;
  list-panes) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

setup_case() {  # <name> -> echoes case dir with home/state + t1 meta
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  printf '%s\n' "$dir"
}

age_activity() {  # <case-dir> <seconds-ago> - age every activity marker
  local dir=$1 ago=$2 marker
  for marker in meta status turn-ended; do
    [ -e "$dir/home/state/t1.$marker" ] || : > "$dir/home/state/t1.$marker"
    touch_ago "$dir/home/state/t1.$marker" "$ago"
  done
}

touch_ago() {  # <path> <seconds-ago>
  local path=$1 ago=$2 stamp
  stamp=$(date -d "@$(( $(date +%s) - ago ))" +%Y%m%d%H%M.%S 2>/dev/null) \
    || stamp=$(date -r "$(( $(date +%s) - ago ))" +%Y%m%d%H%M.%S)
  touch -t "$stamp" "$path"
}

age_marker() {  # <path> <seconds-ago>
  local path=$1 ago=$2
  : > "$path"
  touch_ago "$path" "$ago"
}

run_send() {  # <case-dir> <err-file> [env...] -- <fm-send args...>
  local dir=$1 err=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_SETTLE=0 \
    ${envs[@]+"${envs[@]}"} \
    "$SEND" "$@" >/dev/null 2>"$err"
}

test_unreadable_idle_signal_fails_open() {
  local dir err rc
  dir=$(setup_case unreadable); err="$dir/send.err"
  age_activity "$dir" 40000
  cat > "$dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/fakebin/stat"
  run_send "$dir" "$err" -- t1 "ordinary steer"; rc=$?
  expect_code 0 "$rc" "an unreadable idle signal must fail open, not block the steer"$'\n'"$(cat "$err")"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer should have been durably recorded"
  pass "fm-send cache-stale guard: an unreadable idle signal fails open"
}

test_fresh_marker_not_refused() {
  local dir err rc
  dir=$(setup_case fresh); err="$dir/send.err"
  age_activity "$dir" 60
  run_send "$dir" "$err" -- t1 "ordinary steer"; rc=$?
  expect_code 0 "$rc" "a session idle well under the TTL must not be refused"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer should have been durably recorded"
  pass "fm-send cache-stale guard: idle-under-TTL steer proceeds"
}

test_stale_marker_refused() {
  local dir err rc
  dir=$(setup_case stale); err="$dir/send.err"
  age_activity "$dir" 4000
  run_send "$dir" "$err" -- t1 "ordinary steer"; rc=$?
  expect_code 1 "$rc" "a session idle past the TTL must be refused"
  [ -e "$dir/home/state/t1.inbox/001.msg" ] && fail "a refused steer must never write an inbox record"
  assert_contains "$(cat "$err")" "fm-control.sh t1 relaunch" \
    "the refusal must print the exact relaunch command"
  assert_contains "$(cat "$err")" "--steer-stale" \
    "the refusal must mention the override flag"
  pass "fm-send cache-stale guard: idle-past-TTL steer is refused with the relaunch hint"
}

test_override_flag_sends_anyway() {
  local dir err rc
  dir=$(setup_case override); err="$dir/send.err"
  age_activity "$dir" 4000
  run_send "$dir" "$err" -- t1 --steer-stale "resume anyway"; rc=$?
  expect_code 0 "$rc" "--steer-stale must override the guard"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the overridden steer should have been durably recorded"
  pass "fm-send cache-stale guard: --steer-stale overrides the refusal"
}

test_config_ttl_override() {
  local dir err rc
  dir=$(setup_case configttl); err="$dir/send.err"
  mkdir -p "$dir/home/config"
  printf '60\n' > "$dir/home/config/cache-ttl-seconds"
  age_activity "$dir" 120
  run_send "$dir" "$err" -- t1 "ordinary steer"; rc=$?
  expect_code 1 "$rc" "a lowered config/cache-ttl-seconds must refuse a steer the default TTL would allow"
  pass "fm-send cache-stale guard: config/cache-ttl-seconds overrides the default threshold"
}

test_config_ttl_skips_blank_and_comment_lines() {
  local dir err rc
  dir=$(setup_case ttlcomments); err="$dir/send.err"
  mkdir -p "$dir/home/config"
  printf '\n# lowered while the fleet is churning\n60\n' > "$dir/home/config/cache-ttl-seconds"
  age_activity "$dir" 120
  run_send "$dir" "$err" -- t1 "ordinary steer"; rc=$?
  expect_code 1 "$rc" "the TTL must come from the first non-empty, non-comment line, not a leading blank"
  assert_contains "$(cat "$err")" "60s prompt-cache TTL" \
    "the refusal must report the configured TTL that was actually parsed"
  pass "fm-send cache-stale guard: config/cache-ttl-seconds skips blank and comment lines"
}

test_zero_ttl_disables_guard() {
  local dir err rc
  dir=$(setup_case zerottl); err="$dir/send.err"
  mkdir -p "$dir/home/config"
  printf '0\n' > "$dir/home/config/cache-ttl-seconds"
  age_activity "$dir" 40000
  run_send "$dir" "$err" -- t1 "ordinary steer"; rc=$?
  expect_code 0 "$rc" "a configured TTL of 0 must disable the guard, not refuse every steer"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer should have been durably recorded"
  pass "fm-send cache-stale guard: config/cache-ttl-seconds=0 disables the guard"
}

test_recent_activity_outranks_stale_turn_ended() {
  local dir err rc
  dir=$(setup_case recentactivity); err="$dir/send.err"
  age_activity "$dir" 4000
  touch_ago "$dir/home/state/t1.status" 30
  run_send "$dir" "$err" -- t1 "ordinary steer"; rc=$?
  expect_code 0 "$rc" "idle age is the NEWEST activity marker, so a fresh status must not be refused"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer should have been durably recorded"
  pass "fm-send cache-stale guard: a fresh activity marker outranks a stale turn-ended"
}

test_busy_session_never_refused() {
  local dir err rc
  dir=$(setup_case busy); err="$dir/send.err"
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1 --state busy >/dev/null \
    || fail "could not arm a busy record for the fixture"
  age_activity "$dir" 40000
  touch_ago "$dir/home/state/t1.busy-state" 40000
  touch_ago "$dir/home/state/t1.busy-gen" 40000
  run_send "$dir" "$err" -- t1 "ordinary steer"; rc=$?
  expect_code 0 "$rc" "a session mid-turn has a warm cache and must never be refused"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer should have been durably recorded"
  pass "fm-send cache-stale guard: a busy mid-turn session is never refused"
}

test_resolve_key_answer_ignores_guard() {
  local dir err rc
  dir=$(setup_case resolvekey); err="$dir/send.err"
  age_activity "$dir" 4000
  run_send "$dir" "$err" -- t1 --resolve-key some-key "the answer"; rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || fail "unexpected exit $rc"
  case "$(cat "$err")" in
    *"is not resolvable as an open decision"*) : ;;
    *"no open decision"*) : ;;
    *) [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "a --resolve-key answer must not be blocked by the cache-stale guard" ;;
  esac
  pass "fm-send cache-stale guard: --resolve-key path is unaffected by staleness"
}

test_unreadable_idle_signal_fails_open
test_fresh_marker_not_refused
test_stale_marker_refused
test_override_flag_sends_anyway
test_config_ttl_override
test_config_ttl_skips_blank_and_comment_lines
test_zero_ttl_disables_guard
test_recent_activity_outranks_stale_turn_ended
test_busy_session_never_refused
test_resolve_key_answer_ignores_guard
