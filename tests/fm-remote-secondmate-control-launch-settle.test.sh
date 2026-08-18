#!/usr/bin/env bash
# tests/fm-remote-secondmate-control-launch-settle.test.sh - regression coverage
# for the fm-spawn-remote-relaunch-metadata-race fix.
#
# Recorded diagnosis: bin/fm-remote-secondmate-control.sh's launch command
# returned rc=0 with an empty target= while the just-launched endpoint's Herdr
# metadata was still settling, which fm-spawn.sh's malformed-metadata refusal
# then had to catch. The fix makes cmd_launch itself retry the endpoint-metadata
# read (remote_endpoint_settle) before printing the route, so a transient
# not-yet-settled read never becomes a false rc=0, and a persistently malformed
# read still refuses loudly after the bound instead of being silently accepted.
#
# This drives the real bin/fm-remote-secondmate-control.sh directly (copied into
# an isolated fake bin/ alongside a scripted fm-spawn.sh stand-in, since cmd_launch
# always resolves its nested launcher as "$SCRIPT_DIR/fm-spawn.sh") rather than
# asserting anything about the script's source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-launch-settle)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# cmd_launch always resolves its nested launcher relative to its own script
# directory, so the whole bin/ tree is copied here rather than hand-picking its
# transitive sourcing dependencies (which would silently drift as they change).
FAKE_BIN="$TMP_ROOT/bin"
cp -r "$ROOT/bin" "$FAKE_BIN"

# The stub nested launcher: it always writes SOME endpoint metadata (so
# cmd_launch's own "[ -f "$meta" ] || die ..." guard is satisfied, matching the
# real diagnosis where the nested launch genuinely returned rc=0), but the
# metadata is deliberately incomplete - missing herdr_workspace_id, herdr_tab_id,
# and herdr_pane_id, the exact shape fm_backend_validate_task_endpoint refuses.
# FM_TEST_SPAWN_FIX_DELAY, when set, forks a background writer that replaces it
# with a fully valid record after that many seconds, modeling the endpoint
# settling moments later - exactly what the recorded direct control call
# observed. FM_TEST_SPAWN_CALLS, when set, counts nested-launcher invocations so
# a test can assert the retry loop never re-invokes the launcher itself, only
# re-reads the metadata it already wrote.
cat > "$FAKE_BIN/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1
mkdir -p "$FM_STATE_OVERRIDE"
meta="$FM_STATE_OVERRIDE/$id.meta"
if [ -n "${FM_TEST_SPAWN_CALLS:-}" ]; then
  c=$(cat "$FM_TEST_SPAWN_CALLS" 2>/dev/null || echo 0)
  echo $((c + 1)) > "$FM_TEST_SPAWN_CALLS"
fi
write_incomplete() {
  local tmp="$meta.tmp.$$"
  {
    echo "window=fm-remote:pane1"
    echo "endpoint_task_id=$id"
    echo "worktree=/tmp/fake-worktree"
    echo "project=/tmp/fake-project"
    echo "harness=codex"
    echo "backend=herdr"
    echo "herdr_session=fm-remote"
  } > "$tmp"
  mv -f -- "$tmp" "$meta"
}
write_valid() {
  local tmp="$meta.tmp.$$"
  {
    echo "window=fm-remote:pane1"
    echo "endpoint_task_id=$id"
    echo "worktree=/tmp/fake-worktree"
    echo "project=/tmp/fake-project"
    echo "harness=codex"
    echo "backend=herdr"
    echo "herdr_session=fm-remote"
    echo "herdr_workspace_id=ws1"
    echo "herdr_tab_id=tab1"
    echo "herdr_pane_id=pane1"
  } > "$tmp"
  mv -f -- "$tmp" "$meta"
}
write_incomplete
if [ -n "${FM_TEST_SPAWN_FIX_DELAY:-}" ]; then
  (
    sleep "$FM_TEST_SPAWN_FIX_DELAY"
    write_valid
  ) &
  disown
fi
exit 0
SH
chmod +x "$FAKE_BIN/fm-spawn.sh"

run_launch() { # <target-home> <id> [extra env assignments...]
  local target_home=$1 id=$2
  shift 2
  mkdir -p "$target_home/config"
  printf '%s\n' "$id" > "$target_home/.fm-secondmate-home"
  : > "$target_home/AGENTS.md"
  mkdir -p "$target_home/bin"
  env "$@" FM_HOME="$target_home" \
    "$FAKE_BIN/fm-remote-secondmate-control.sh" launch "$id" codex - - herdr
}

# --- transiently-empty target that settles within the bound: succeeds -------
TARGET_A="$TMP_ROOT/target-a"
CALLS_A="$TMP_ROOT/calls-a"
OUT_A=$(run_launch "$TARGET_A" secondmate-a \
  FM_TEST_SPAWN_FIX_DELAY=0.1 FM_TEST_SPAWN_CALLS="$CALLS_A" \
  FM_REMOTE_LAUNCH_SETTLE_ATTEMPTS=20 FM_REMOTE_LAUNCH_SETTLE_SLEEP=0.05 2>&1)
RC_A=$?
[ "$RC_A" -eq 0 ] \
  || fail "a transiently-empty target that settles within the bound must still succeed (rc=$RC_A): $OUT_A"
assert_contains "$OUT_A" "target=fm-remote:pane1" \
  "a settled relaunch must report the real, non-empty endpoint target"
[ "$(cat "$CALLS_A")" = 1 ] \
  || fail "the retry loop must re-read the metadata it already wrote, never re-invoke the nested launcher"
pass "a transiently-empty target that settles within the bound succeeds with the real route"

# --- persistently-empty target beyond the bound: refuses loudly -------------
TARGET_B="$TMP_ROOT/target-b"
OUT_B=$(run_launch "$TARGET_B" secondmate-b \
  FM_REMOTE_LAUNCH_SETTLE_ATTEMPTS=3 FM_REMOTE_LAUNCH_SETTLE_SLEEP=0.05 2>&1)
RC_B=$?
[ "$RC_B" -ne 0 ] \
  || fail "a persistently malformed target must never be silently accepted as rc=0, got: $OUT_B"
assert_not_contains "$OUT_B" "target=" \
  "a refused launch must never print a route line, empty or otherwise"
assert_contains "$OUT_B" "error:" \
  "a persistently malformed target must refuse loudly with a visible error"
pass "a persistently-empty target still refuses loudly after the bound"

echo "ALL TESTS PASSED"
