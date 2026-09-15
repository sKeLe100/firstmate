#!/usr/bin/env bash
# Regression coverage for the FM_CREW_STATE_META_OVERRIDE/
# FM_CREW_STATE_STATUS_OVERRIDE leak: the only setter in the repo is the
# per-command `env VAR=val cmd` prefix in bin/fm-fleet-snapshot.sh's
# crew_state_json, which is scoped to that one child and never exported to the
# calling shell. The real leak path is whichever shell exported these vars
# (interactively, or via a stray `export` while debugging) and then started
# the herdr primary server or a crewmate pane: both must not let an ambient
# export ride into a spawned worker's or the herdr server's own environment.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state-env-leak)

# --- fm-spawn.sh: crewmate launch must strip both overrides ----------------
#
# fm-spawn.sh's shared harness-marker env -u prefix (around the claude/codex/
# opencode/pi/pi-signed/grok/kimi/gemini/muse/rovo case, plus cursor's own
# inline env -u list) is the one place that wraps every crewmate launch
# command; it must clear FM_CREW_STATE_META_OVERRIDE and
# FM_CREW_STATE_STATUS_OVERRIDE alongside the existing CURSOR_AGENT/
# CURSOR_INVOKED_AS/GEMINI_CLI markers so neither leaks into the launched
# pane's environment.

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

test_spawn_launch_strips_crew_state_overrides() {
  local case_dir home proj wt fakebin id out status launch
  case_dir="$TMP_ROOT/spawn-strip"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="crew-state-leak-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the env-leak regression.

## Firstmate spec
Verify FM_CREW_STATE_*_OVERRIDE never reaches a spawned pane.
EOF
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_CREW_STATE_META_OVERRIDE="$case_dir/leaked.meta" \
    FM_CREW_STATE_STATUS_OVERRIDE="$case_dir/leaked.status" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" claude --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "claude spawn under an exported crew-state override should still succeed: $out"

  launch=$(cat "$home/launch.log")
  assert_contains "$launch" 'env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u FM_CREW_STATE_META_OVERRIDE -u FM_CREW_STATE_STATUS_OVERRIDE' \
    "claude launch did not strip the inherited crew-state overrides"
  pass "fm-spawn strips FM_CREW_STATE_META_OVERRIDE/FM_CREW_STATE_STATUS_OVERRIDE from a crewmate launch"
}

# --- herdr server_ensure: the server's own startup env must not carry them --

test_herdr_server_ensure_unsets_crew_state_overrides() {
  local dir fakebin envfile out
  dir="$TMP_ROOT/herdr-server"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir/fake")
  envfile="$dir/server-env"
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"status --json"*)
    if [ -f "$dir/running" ]; then
      printf '{"server":{"running":true}}\n'
    else
      printf '{"server":{"running":false}}\n'
    fi
    exit 0
    ;;
  "server "*|"server")
    env > "$envfile"
    : > "$dir/running"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"

  out=$(
    PATH="$fakebin:$PATH" \
    FM_CREW_STATE_META_OVERRIDE="$dir/leaked.meta" \
    FM_CREW_STATE_STATUS_OVERRIDE="$dir/leaked.status" \
    bash -c '
      set -u
      # shellcheck source=bin/backends/herdr.sh
      . "'"$ROOT"'/bin/backends/herdr.sh"
      fm_backend_herdr_server_ensure fake-session
    ' 2>&1
  )
  status=$?
  expect_code 0 "$status" "fm_backend_herdr_server_ensure should succeed: $out"
  assert_present "$envfile" "the fake herdr server was never invoked"
  assert_no_grep 'FM_CREW_STATE_META_OVERRIDE' "$envfile" \
    "herdr server startup env still carried FM_CREW_STATE_META_OVERRIDE"
  assert_no_grep 'FM_CREW_STATE_STATUS_OVERRIDE' "$envfile" \
    "herdr server startup env still carried FM_CREW_STATE_STATUS_OVERRIDE"
  pass "fm_backend_herdr_server_ensure unsets FM_CREW_STATE_META_OVERRIDE/FM_CREW_STATE_STATUS_OVERRIDE before starting the server"
}

test_spawn_launch_strips_crew_state_overrides
test_herdr_server_ensure_unsets_crew_state_overrides
