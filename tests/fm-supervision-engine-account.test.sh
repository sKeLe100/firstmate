#!/usr/bin/env bash
# Behavior tests for the supervision engine's opt-in Claude account
# (config/supervision-engine-account, bin/fm-supervision-engine-lib.sh): a
# present file selects the CLAUDE_CONFIG_DIR the headless engine launches with,
# an absent file keeps today's inherited account, and an unusable file leaves
# the home without an engine instead of falling back.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-engine-account)
PRIMARY="$TMP_ROOT/primary-account"
ACCOUNT="$TMP_ROOT/selected-account"
mkdir -p "$PRIMARY" "$ACCOUNT"

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/root"
  # An empty file opts the home into the supervision host at its default engine.
  : > "$home/config/supervision-host"
  printf '%s\n' "$home"
}

make_stub() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
{
  printf 'CLAUDE_CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR-unset}"
  for a in "$@"; do printf 'arg=%s\n' "$a"; done
} > "$FM_TEST_ENGINE_LOG"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.5,"usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}\n'
SH
  chmod +x "$1"
}

read_config() {  # <home>; prints "engine|model|account|problem"
  (
    unset FM_SUPERVISION_ENGINE_ACCOUNT
    # The home and config overrides are deliberately scoped to this subshell.
    # shellcheck disable=SC2030,SC2031
    export FM_HOME="$1" FM_CONFIG_OVERRIDE="$1/config"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$ROOT/bin/fm-timeout-lib.sh"
    # shellcheck source=bin/fm-supervision-engine-lib.sh
    . "$ROOT/bin/fm-supervision-engine-lib.sh"
    fm_supervision_host_config "$1/config" claude
    printf '%s|%s|%s|%s\n' "$FM_SUPERVISION_ENGINE" "$FM_SUPERVISION_ENGINE_MODEL" \
      "$FM_SUPERVISION_ENGINE_ACCOUNT" "$FM_SUPERVISION_ENGINE_PROBLEM"
  )
}

run_turn() {  # <home> <stub>
  local home=$1 stub=$2
  printf 'prompt\n' > "$home/prompt"
  printf 'wake\n' > "$home/message"
  (
    export FM_TEST_ENGINE_LOG="$home/engine.log"
    export CLAUDE_CONFIG_DIR="$PRIMARY"
    # Every engine path is deliberately scoped to this turn's subshell.
    # shellcheck disable=SC2030,SC2031
    export FM_ROOT="$home/root" FM_HOME="$home" STATE="$home/state"
    # shellcheck disable=SC2030,SC2031
    export FM_CONFIG_OVERRIDE="$home/config"
    export FM_SUPERVISION_ENGINE_CLAUDE_BIN="$stub"
    unset FM_SUPERVISION_ENGINE_ACCOUNT
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$ROOT/bin/fm-timeout-lib.sh"
    # shellcheck source=bin/fm-supervision-engine-lib.sh
    . "$ROOT/bin/fm-supervision-engine-lib.sh"
    fm_supervision_engine_turn claude sonnet "$home/prompt" "$home/message" \
      session-1 new 60 "$home/result" "$home/errors"
  ) >"$home/turn.out" 2>&1
}

test_absent_file_keeps_the_inherited_account() {
  local home stub account rc
  home=$(make_home absent)
  stub="$TMP_ROOT/stub-absent"
  make_stub "$stub"

  account=$(read_config "$home" | awk -F'|' '{ print $3 }')
  [ -z "$account" ] || fail "an absent account file must select no explicit account"

  run_turn "$home" "$stub"
  rc=$?
  expect_code 0 "$rc" "a turn on an unpinned home must still run"
  assert_grep "CLAUDE_CONFIG_DIR=$PRIMARY" "$home/engine.log" \
    "an absent account file must keep the engine on the inherited CLAUDE_CONFIG_DIR"
  assert_grep 'arg=--safe-mode' "$home/engine.log" "the turn must keep its ordinary argument contract"
  pass "an absent config/supervision-engine-account keeps today's inherited account"
}

test_present_file_selects_the_engine_account() {
  local home stub account rc
  home=$(make_home opted-in)
  stub="$TMP_ROOT/stub-opted-in"
  make_stub "$stub"
  printf '%s\n' "$ACCOUNT" > "$home/config/supervision-engine-account"

  account=$(read_config "$home" | awk -F'|' '{ print $3 }')
  [ "$account" = "$ACCOUNT" ] || fail "a present account file must reach the host config as the engine account"

  run_turn "$home" "$stub"
  rc=$?
  expect_code 0 "$rc" "a turn with a usable account file must run"
  assert_grep "CLAUDE_CONFIG_DIR=$ACCOUNT" "$home/engine.log" \
    "the engine must launch with the selected config directory"
  assert_no_grep "CLAUDE_CONFIG_DIR=$PRIMARY" "$home/engine.log" \
    "the engine must not keep the inherited config directory once the file selects another"
  pass "a present config/supervision-engine-account moves the engine to that account"
}

test_unusable_files_leave_the_home_without_an_engine() {
  local home out
  home=$(make_home bad-relative)
  printf 'relative/account\n' > "$home/config/supervision-engine-account"
  out=$(read_config "$home")
  [ -z "$(printf '%s\n' "$out" | awk -F'|' '{ print $1 }')" ] || fail "a relative path must not select an engine account"
  assert_grep 'config/supervision-engine-account' <(printf '%s\n' "$out" | awk -F'|' '{ print $4 }') \
    "a relative path must be named as the reason there is no engine"

  home=$(make_home bad-empty)
  : > "$home/config/supervision-engine-account"
  out=$(read_config "$home")
  [ -z "$(printf '%s\n' "$out" | awk -F'|' '{ print $1 }')" ] || fail "an empty account file must not select an engine account"
  assert_grep 'empty' <(printf '%s\n' "$out" | awk -F'|' '{ print $4 }') \
    "an empty file must say to remove it"

  home=$(make_home bad-missing)
  printf '%s\n' "$TMP_ROOT/no-such-account" > "$home/config/supervision-engine-account"
  out=$(read_config "$home")
  [ -z "$(printf '%s\n' "$out" | awk -F'|' '{ print $1 }')" ] || fail "a nonexistent directory must not select an engine account"
  assert_grep 'existing readable directory' <(printf '%s\n' "$out" | awk -F'|' '{ print $4 }') \
    "a nonexistent directory must be named as the reason there is no engine"

  home=$(make_home bad-two-lines)
  printf '%s\n%s\n' "$ACCOUNT" "$ACCOUNT" > "$home/config/supervision-engine-account"
  out=$(read_config "$home")
  [ -z "$(printf '%s\n' "$out" | awk -F'|' '{ print $1 }')" ] || fail "a multi-line file must not select an engine account"
  assert_grep 'no other line' <(printf '%s\n' "$out" | awk -F'|' '{ print $4 }') \
    "a multi-line file must be named as the reason there is no engine"
  pass "an unusable account file leaves the home without an engine and names the file"
}

test_unusable_file_refuses_the_turn_instead_of_falling_back() {
  local home stub rc
  home=$(make_home turn-bad)
  stub="$TMP_ROOT/stub-turn-bad"
  make_stub "$stub"
  printf 'relative/account\n' > "$home/config/supervision-engine-account"

  run_turn "$home" "$stub"
  rc=$?
  expect_code 127 "$rc" "a declared but unusable account must refuse the engine launch"
  assert_grep 'config/supervision-engine-account' "$home/errors" \
    "the refusal must name the file to fix"
  assert_absent "$home/engine.log" "the engine must not launch on the declined inherited account"
  pass "an unusable account refuses the launch rather than falling back to the inherited account"
}

test_absent_file_keeps_the_inherited_account
test_present_file_selects_the_engine_account
test_unusable_files_leave_the_home_without_an_engine
test_unusable_file_refuses_the_turn_instead_of_falling_back

echo "# all fm-supervision-engine-account tests passed"
