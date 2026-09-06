#!/usr/bin/env bash
# fm-spawn.sh codex guards (Phase 1b, data/codex-secondmate-integration-plan;
# the captain's one-lane rule):
#   1. codex_lane_guard refuses a spawn while another Codex task in this home
#      is alive or unconfirmed, naming the conflicting task id, allows it once
#      dead, and ignores remote-routed Codex metas (the lane is per home).
#   2. A raw custom Codex launch command is refused unless the executable it
#      names resolves (readlink -f) to the freshly rediscovered codex exe.
#   3. The composed codex launch line never contains --fast, and any launch
#      command carrying the fast modifier is refused outright (the captain was
#      previously burned by --fast on claude specifically).
#   4. A raw codex launch is pinned to the probed absolute executable, and a
#      differently-named binary that resolves to codex still takes the lane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-codex-guards)

make_case() {  # <name> [task-id...]
  local name=$1 case_dir home proj wt fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *pane_current_command*) printf '%s\n' "${FM_FAKE_PANE_CMD:-firstmate}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_LIST_WINDOWS_ERR:-}" ]; then
      echo "fake inventory failure" >&2
      exit 1
    fi
    printf '%s' "${FM_FAKE_WINDOWS:-}"
    exit 0
    ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ] && [ -n "${D:-}" ]; then
      printf '%s\n' "${1:-}" >> "$D/literal"
    fi
    exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'codex-cli 0.153.4\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/codex"
  fm_fake_exit0 "$fakebin" treehouse
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$case_dir/fake"
  : > "$case_dir/fake/literal"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf '# Task\n## Captain'"'"'s intent\nbrief for %s\n\n## Firstmate spec\nExercise the spawn behavior under test.\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

write_other_codex_meta() {  # <home> <task>
  cat > "$1/state/$2.meta" <<EOF
window=firstmate:fm-$2
endpoint_task_id=$2
harness=codex
kind=ship
model=default
EOF
}

fake_windows_for() {  # <task...> -> tmux list-windows -F '#{window_name}' output
  local id
  for id in "$@"; do
    printf 'fm-%s\n' "$id"
  done
}

run_spawn() {  # <home> <wt> <fakebin> <id> <proj> <extra args...>
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_DIR="$CASE_DIR/fake" \
    TMUX="fake,1,0" CLAUDE_CONFIG_DIR='' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --harness codex --mode no-mistakes --yolo off "$@" 2>&1
}

test_codex_remote_route_does_not_occupy_local_lane() {
  local rec id out status
  id=codex-remote-ignored
  rec=$(make_case remote-lane "$id")
  read_case_record "$rec"
  write_other_codex_meta "$HOME_DIR" remote-codex
  printf 'remote_host=example.test\n' >> "$HOME_DIR/state/remote-codex.meta"
  out=$(FM_FAKE_WINDOWS="$(fake_windows_for remote-codex)" \
    FM_FAKE_PANE_CMD=codex \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a remote Codex route must not occupy this home's Codex lane even when a same-named local window reads alive: $out"
  pass "a remote-routed Codex meta does not occupy this home's Codex lane"
}

test_codex_lane_guard_refuses_live_task_and_names_it() {
  local rec id out status
  id=codex-guard-a1
  rec=$(make_case live-lane "$id")
  read_case_record "$rec"
  write_other_codex_meta "$HOME_DIR" other-codex-task

  out=$(FM_FAKE_WINDOWS="$(fake_windows_for other-codex-task)" \
    FM_FAKE_PANE_CMD=codex \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "one confirmed-alive Codex task must block a spawn: $out"
  assert_contains "$out" "other-codex-task" "the refusal did not name the live task: $out"
  pass "codex_lane_guard refuses a spawn while another Codex task is live"
}

test_codex_lane_guard_serializes_against_unconfirmed_launch() {
  local rec id out status
  id=codex-guard-a3
  rec=$(make_case launching "$id")
  read_case_record "$rec"
  write_other_codex_meta "$HOME_DIR" launching-codex-task

  out=$(FM_FAKE_WINDOWS="$(fake_windows_for launching-codex-task)" \
    FM_FAKE_PANE_CMD=firstmate \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a spawn must refuse while another codex task's launch is still unconfirmed: $out"
  assert_contains "$out" "Codex lane occupied in this home" "the refusal did not name the per-home lane guard: $out"
  assert_contains "$out" "launching-codex-task" "the refusal did not name the unconfirmed task: $out"
  pass "codex_lane_guard refuses a spawn while another codex task is still launching/unconfirmed"
}

test_codex_lane_guard_allows_when_other_codex_is_dead() {
  local rec id out status
  id=codex-guard-a5
  rec=$(make_case deadlane "$id")
  read_case_record "$rec"
  write_other_codex_meta "$HOME_DIR" dead-codex-task

  out=$(FM_FAKE_WINDOWS='' run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a dead prior codex task must not block a fresh spawn: $out"
  pass "codex_lane_guard allows a spawn once the other codex endpoint reads dead"
}

run_raw_spawn() {  # <home> <wt> <fakebin> <id> <proj> <raw launch command>
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5 raw=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_DIR="$CASE_DIR/fake" \
    TMUX="fake,1,0" CLAUDE_CONFIG_DIR='' PATH="$fakebin:$PATH" FM_FAKE_WINDOWS="${FM_FAKE_WINDOWS:-}" \
    "$SPAWN" "$id" "$proj" "$raw" --mode no-mistakes --yolo off 2>&1
}

test_composed_codex_launch_line_never_contains_fast() {
  local rec id status
  id=codex-guard-b1
  rec=$(make_case codexfast "$id")
  read_case_record "$rec"

  FM_FAKE_WINDOWS='' run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "the codex spawn used to compose the launch line should succeed"
  if grep -q -- '--fast' "$CASE_DIR/fake/literal" 2>/dev/null; then
    fail "the composed codex launch line must never contain --fast: $(cat "$CASE_DIR/fake/literal")"
  fi
  pass "the composed codex launch line never contains --fast"
}

test_raw_launch_with_fast_modifier_is_refused() {
  local rec id out status
  id=codex-guard-b2
  rec=$(make_case claudefast "$id")
  read_case_record "$rec"

  out=$(run_raw_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" "claude --fast --dangerously-skip-permissions")
  status=$?
  expect_code 1 "$status" "a launch command carrying --fast must be refused: $out"
  assert_contains "$out" "fast modifier" "the refusal did not name the fast modifier: $out"
  if [ -s "$CASE_DIR/fake/literal" ]; then
    fail "the refused --fast launch must not be sent to the pane: $(cat "$CASE_DIR/fake/literal")"
  fi
  pass "a launch command carrying the fast modifier is refused"
}

test_raw_codex_bare_name_is_pinned_to_the_resolved_exe() {
  local rec id out status resolved sent
  id=codex-raw-pinned
  rec=$(make_case rawpinned "$id")
  read_case_record "$rec"
  resolved=$(readlink -f -- "$FAKEBIN_DIR/codex")

  out=$(run_raw_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" "codex --dangerously-bypass-approvals-and-sandbox")
  status=$?
  expect_code 0 "$status" "a raw codex launch naming the rediscovered exe must be allowed: $out"
  sent=$(cat "$CASE_DIR/fake/literal")
  assert_contains "$sent" "$resolved" "the launch line sent to the pane must name the probed codex executable, not a bare name: $sent"
  pass "a bare-name raw codex launch is sent to the pane as the probed absolute executable"
}

test_raw_codex_alias_takes_the_codex_lane() {
  local rec id out status alias
  id=codex-raw-alias
  rec=$(make_case rawalias "$id")
  read_case_record "$rec"
  mkdir -p "$CASE_DIR/aliasbin"
  alias="$CASE_DIR/aliasbin/cdx"
  ln -sf "$FAKEBIN_DIR/codex" "$alias"
  write_other_codex_meta "$HOME_DIR" other-codex-task

  out=$(FM_FAKE_WINDOWS="$(fake_windows_for other-codex-task)" FM_FAKE_PANE_CMD=codex     run_raw_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" "$alias --dangerously-bypass-approvals-and-sandbox")
  status=$?
  expect_code 1 "$status" "a raw launch of a differently-named binary that resolves to codex must take the Codex lane: $out"
  assert_contains "$out" "Codex lane occupied in this home" "the alias launch bypassed the per-home Codex lane guard: $out"
  pass "a raw launch aliasing the codex binary is classified as codex and takes the lane"
}

test_raw_codex_launch_with_env_prefix_pins_the_exe() {
  local rec id out status resolved sent
  id=codex-raw-envprefix
  rec=$(make_case rawenv "$id")
  read_case_record "$rec"
  resolved=$(readlink -f -- "$FAKEBIN_DIR/codex")

  out=$(run_raw_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    "CODEX_HOME=$CASE_DIR/.codex codex --dangerously-bypass-approvals-and-sandbox")
  status=$?
  expect_code 0 "$status" "a raw codex launch with an env-assignment prefix must be allowed: $out"
  sent=$(cat "$CASE_DIR/fake/literal")
  assert_contains "$sent" "CODEX_HOME=$CASE_DIR/.codex" "the env assignment preceding the executable must be sent verbatim: $sent"
  assert_contains "$sent" "$resolved" "the executable word must be pinned to the probed codex path: $sent"
  if printf '%s' "$sent" | grep -qE "(^|[[:space:]])codex([[:space:]]|$)"; then
    fail "the launch line must not still invoke codex by bare name: $sent"
  fi
  pass "a raw codex launch with env-assignment prefixes pins only the executable word"
}

test_codex_effort_max_is_reachable_without_an_explicit_model() {
  local rec id out status catalog codex_home
  id=codex-effort-max
  rec=$(make_case effortmax "$id")
  read_case_record "$rec"
  catalog="$CASE_DIR/codex-models-cache.json"
  cat > "$catalog" <<'JSON'
{"models":[
  {"slug":"gpt-5.6-luna","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}]},
  {"slug":"gpt-5.5","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}]}
]}
JSON
  codex_home="$CASE_DIR/codex-home"
  mkdir -p "$codex_home"
  printf 'model = "gpt-5.6-luna"\n' > "$codex_home/config.toml"

  out=$(FM_TEST_CODEX_MODELS_CACHE="$catalog" CODEX_HOME="$codex_home" FM_FAKE_WINDOWS='' \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --effort max)
  status=$?
  expect_code 0 "$status" "effort max must stay reachable when codex's own default model lists it: $out"
  assert_contains "$(cat "$CASE_DIR/fake/literal")" 'model_reasoning_effort="max"' "the launch line must carry the max reasoning effort"
  pass "codex effort max is reachable without naming a model when the default model supports it"
}

test_codex_effort_refused_when_default_model_lacks_it() {
  local rec id out status catalog codex_home
  id=codex-effort-nomax
  rec=$(make_case effortnomax "$id")
  read_case_record "$rec"
  catalog="$CASE_DIR/codex-models-cache.json"
  cat > "$catalog" <<'JSON'
{"models":[
  {"slug":"gpt-5.6-luna","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}]},
  {"slug":"gpt-5.5","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}]}
]}
JSON
  codex_home="$CASE_DIR/codex-home"
  mkdir -p "$codex_home"
  printf 'model = "gpt-5.5"\n' > "$codex_home/config.toml"

  out=$(FM_TEST_CODEX_MODELS_CACHE="$catalog" CODEX_HOME="$codex_home" FM_FAKE_WINDOWS='' \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --effort max)
  status=$?
  expect_code 1 "$status" "an effort the resolved default model does not list must be refused: $out"
  assert_contains "$out" "gpt-5.5" "the refusal did not name the resolved default model: $out"
  if grep -q 'model_reasoning_effort' "$CASE_DIR/fake/literal" 2>/dev/null; then
    fail "the refused effort must never reach a launch line: $(cat "$CASE_DIR/fake/literal")"
  fi
  pass "codex refuses an effort the resolved default model does not list"
}

test_raw_launch_with_unclassifiable_executable_is_refused() {
  local rec id out status
  id=codex-raw-quoted-env
  rec=$(make_case rawquoted "$id")
  read_case_record "$rec"

  out=$(run_raw_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    "CODEX_HOME=\"$CASE_DIR/my codex\" codex --dangerously-bypass-approvals-and-sandbox")
  status=$?
  expect_code 1 "$status" "a raw launch whose executable word cannot be resolved must be refused: $out"
  assert_contains "$out" "quotes text before its executable word" "the refusal did not name the unparsable quoting: $out"
  if [ -s "$CASE_DIR/fake/literal" ]; then
    fail "the refused raw launch must not be sent to the pane: $(cat "$CASE_DIR/fake/literal")"
  fi
  pass "a raw launch with a quoted env value that hides the executable word is refused"
}

test_raw_codex_launch_refuses_foreign_executable() {
  local rec id out status other
  id=codex-raw-foreign
  rec=$(make_case rawforeign "$id")
  read_case_record "$rec"
  mkdir -p "$CASE_DIR/nightly"
  other="$CASE_DIR/nightly/codex"
  cp "$FAKEBIN_DIR/codex" "$other"
  chmod +x "$other"

  out=$(run_raw_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" "$other --dangerously-bypass-approvals-and-sandbox")
  status=$?
  expect_code 1 "$status" "a raw codex launch naming a binary other than the rediscovered exe must be refused: $out"
  assert_contains "$out" "$other" "the refusal did not name the raw command's executable: $out"
  assert_contains "$out" "$(readlink -f -- "$FAKEBIN_DIR/codex")" "the refusal did not name the rediscovered codex exe: $out"
  if [ -s "$CASE_DIR/fake/literal" ]; then
    fail "the refused raw codex launch must not be sent to the pane: $(cat "$CASE_DIR/fake/literal")"
  fi
  pass "a raw codex launch command is refused unless it names the rediscovered exe"
}

test_raw_codex_launch_allows_rediscovered_executable() {
  local rec id out status
  id=codex-raw-same
  rec=$(make_case rawsame "$id")
  read_case_record "$rec"

  out=$(run_raw_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" "codex --dangerously-bypass-approvals-and-sandbox")
  status=$?
  expect_code 0 "$status" "a raw codex launch naming the rediscovered exe must be allowed: $out"
  assert_contains "$(cat "$HOME_DIR/state/$id.meta")" "codex_exe=$(readlink -f -- "$FAKEBIN_DIR/codex")" "meta must record the rediscovered codex exe as audit evidence"
  pass "a raw codex launch command naming the rediscovered exe launches"
}

test_raw_codex_launch_refuses_foreign_executable
test_raw_codex_launch_allows_rediscovered_executable
test_codex_remote_route_does_not_occupy_local_lane
test_codex_lane_guard_refuses_live_task_and_names_it
test_codex_lane_guard_serializes_against_unconfirmed_launch
test_codex_lane_guard_allows_when_other_codex_is_dead
test_composed_codex_launch_line_never_contains_fast
test_raw_launch_with_fast_modifier_is_refused
test_raw_codex_bare_name_is_pinned_to_the_resolved_exe
test_raw_codex_alias_takes_the_codex_lane
test_raw_codex_launch_with_env_prefix_pins_the_exe
test_codex_effort_max_is_reachable_without_an_explicit_model
test_codex_effort_refused_when_default_model_lacks_it
test_raw_launch_with_unclassifiable_executable_is_refused

echo "# all fm-spawn-codex-guards tests passed"
