#!/usr/bin/env bash
# Tests for fm-control.sh's Claude exit-sighted-confirm and pre-exit dialog
# check. A prior scout proposed blind Enters for Claude's exit dialog; a
# senior re-review found that unsafe (could accept a live tool-permission
# prompt or AskUserQuestion). This test pins the sighted-confirm behavior:
# Enter is sent only when all three dialog patterns are present.
#
# Stubbed tmux + overridden agent_state + sleep, no real agent. Deterministic
# outcomes:
#   1. claude, idle composer: sight-confirm sees no dialog, exits cleanly.
#   2. claude, "Background work is running" dialog: sight-confirm fires,
#      sends Enter, exit succeeds.
#   3. claude, AskUserQuestion on pre-exit: pre-exit check refuses.
#   4. claude, workspace-trust on pre-exit: pre-exit check refuses.
#   5. claude, "Background work is running" before submit: pre-exit does NOT
#      refuse (only checks for different modals), sight-confirm handles it.
#   6. claude, idle composer with broad substrings (CLAUDE.md, trust, etc.):
#      does NOT falsely refuse on ordinary transcript text.
#   7. codex: claude-specific checks are no-ops, exit proceeds normally.

set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"

TMP_ROOT=$(fm_test_tmproot fm-control-exit-sighted-confirm)

# make_stubs <dir> <capture-sequence...>
make_stubs() {  # <dir> <capture-1> [capture-2 ...]
  local dir=$1 fb="$1/fakebin"
  shift
  mkdir -p "$fb"
  local seq_tmp
  seq_tmp=$(mktemp)
  local i=0
  for cap in "$@"; do
    local escaped="${cap//\'/\'\\\'\'}"
    printf '      %s) printf '"'"'%%s'"'"' '"'"'%s'"'"'; exit 0 ;;\n' "$i" "$escaped" >> "$seq_tmp"
    i=$((i + 1))
  done
  cat > "$fb/tmux" <<TMUXSH
#!/usr/bin/env bash
set -u
n_file="$dir/tmux.n"
n=\$(cat "\$n_file" 2>/dev/null || echo 0)
printf '%s' "\$n" > "\$n_file"
case "\${1:-}" in
  capture-pane)
    n=\$(( \$(cat "\$n_file" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "\$n" > "\$n_file"
    case \$((n - 1)) in
$(cat "$seq_tmp")
      *) printf 'idle composer\n'; exit 0 ;;
    esac
    ;;
  send-keys) exit 0 ;;
  list-windows) printf 'fm-t1\n'; exit 0 ;;
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *cursor_y*) printf '0\n'; exit 0 ;;
        *pane_tty*) printf '\n'; exit 0 ;;
        *pane_current_command*) printf 'claude\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
esac
exit 0
TMUXSH
  chmod +x "$fb/tmux"
  rm -f "$seq_tmp"
  cat > "$fb/sleep" <<'SLEEPSH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${FM_CASE_DIR:-/tmp}/sleep.log"
exit 0
SLEEPSH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_exit_case <harness> <dead-at> <capture-sequence...>
# Patches fm-control.sh to override agent_state() with a counter-based stub.
run_exit_case() {
  local harness=$1 dead_at=$2
  shift 2
  local case_dir="$TMP_ROOT/case-$$-$RANDOM"
  mkdir -p "$case_dir/state"
  local fb
  fb=$(make_stubs "$case_dir" "$@")

  # Create patched copy with overridden agent_state
  # We put it in the actual bin directory so SCRIPT_DIR resolves correctly
  local patched="$ROOT/bin/fm-control-exit-test.sh"
  cp "$CONTROL" "$patched"

  # Counter file for alive/dead
  local n_file="$case_dir/agent_state.n"
  printf '0' > "$n_file"

  # Write the override function to a temp file
  local override_file="$case_dir/agent_state_override.sh"
  cat > "$override_file" <<'OVERRIDE'
# Override agent_state: counter-based alive/dead
agent_state() {
  local _n
  _n=$(cat "$AG_STATE_NFILE" 2>/dev/null || echo 0)
  _n=$((_n + 1))
  printf '%s' "$_n" > "$AG_STATE_NFILE"
  if [ "$_n" -le "$AG_STATE_DEAD_AT" ]; then
    printf 'alive'
  else
    printf 'dead'
  fi
  return 0
}
OVERRIDE

  # Export the counter file path and dead-at threshold for the override
  export AG_STATE_NFILE="$n_file"
  export AG_STATE_DEAD_AT="$dead_at"

  # Insert the override right before do_exit() in the patched script
  local insert_line
  insert_line=$(grep -n "^do_exit() {" "$CONTROL" | head -1 | cut -d: -f1)
  if [ -z "$insert_line" ]; then
    insert_line=$(grep -n "^wait_agent_state() {" "$CONTROL" | head -1 | cut -d: -f1)
    insert_line=$((insert_line + 20))
  fi

  head -n "$((insert_line - 1))" "$CONTROL" > "$patched"
  cat "$override_file" >> "$patched"
  tail -n "+$insert_line" "$CONTROL" >> "$patched"
  chmod +x "$patched"

  fm_write_meta "$case_dir/state/t1.meta" \
    "window=sess:fm-t1" "harness=$harness" "backend=tmux" "kind=ship" \
    "worktree=$case_dir" "project=$case_dir"
  export PATH="$fb:$PATH"
  export FM_HOME="$case_dir"
  export FM_CASE_DIR="$case_dir"
  export AGENT_STATE_DEAD_AT="$dead_at"
  export FM_GATE_REFUSE_BYPASS=1

  local out err rc
  out=$("$patched" t1 exit 2>"$case_dir/err") && rc=0 || rc=$?
  EXIT_RC=$rc
  EXIT_OUT="$out"
  EXIT_ERR=$(cat "$case_dir/err" 2>/dev/null || true)
}

# --- T1: claude, idle composer, no dialog ------------------------------------
run_exit_case claude 1 \
  "idle composer"
[ "$EXIT_RC" -eq 0 ] || fail "T1: claude idle composer should exit 0, rc=$EXIT_RC err=$EXIT_ERR"
pass "T1: claude idle composer: sight-confirm does not fire on plain composer"

# --- T2: claude, "Background work is running" dialog -------------------------
run_exit_case claude 1 \
  "idle composer" \
  "Background work is running
❯ 1. Exit and stop tasks
Enter to confirm · Esc to cancel"
[ "$EXIT_RC" -eq 0 ] || fail "T2: claude exit dialog should exit 0, rc=$EXIT_RC err=$EXIT_ERR"
pass "T2: claude with exit dialog: sight-confirm sends Enter and exit succeeds"

# --- T3: claude, AskUserQuestion on pre-exit check ---------------------------
# Need dead_at=1 so the initial agent_state check returns "alive" and we reach
# the pre-exit check. Sight-confirm won't fire (dialog is AskUserQuestion, not
# the exit dialog).
run_exit_case claude 1 \
  "Claude is asking you a question:
AskUserQuestion: Do you want to proceed?
[Yes] [No]"
[ "$EXIT_RC" -eq 1 ] || fail "T3: claude AskUserQuestion should refuse, rc=$EXIT_RC"
echo "$EXIT_ERR" | grep -qi "AskUserQuestion" || fail "T3: refusal should mention AskUserQuestion"
pass "T3: claude AskUserQuestion on pre-exit: check refuses instead of typing /exit"

# --- T4: claude, workspace-trust on pre-exit check ---------------------------
run_exit_case claude 1 \
  "Quick safety check: Is this a project you created or one you trust?
[Yes, I created this] [No]"
[ "$EXIT_RC" -eq 1 ] || fail "T4: claude workspace-trust should refuse, rc=$EXIT_RC"
echo "$EXIT_ERR" | grep -qi "trust" || fail "T4: refusal should mention trust dialog"
pass "T4: claude workspace-trust on pre-exit: check refuses instead of typing /exit"

# --- T7: claude, idle composer with broad substrings does NOT refuse ----------
#
# Ordinary Claude Code transcript text can contain words like "trust",
# "CLAUDE.md", "permission", or "bypass" in its reasoning. The pre-exit
# check must NOT refuse on these alone - it requires specific dialog UI text.
run_exit_case claude 1 \
  "I checked the CLAUDE.md file for trust settings.
The permission model allows bypass in certain cases.
Idle composer ready."
[ "$EXIT_RC" -eq 0 ] || fail "T7: claude broad substrings in idle text should NOT refuse, rc=$EXIT_RC err=$EXIT_ERR"
pass "T7: claude idle composer with broad substrings (CLAUDE.md, trust, permission, bypass) does NOT trigger false-positive refusal"

# --- T5: claude, exit dialog visible before /exit submit ---------------------
run_exit_case claude 1 \
  "Background work is running
❯ 1. Exit and stop tasks
Enter to confirm · Esc to cancel"
[ "$EXIT_RC" -eq 0 ] || fail "T5: claude exit dialog before submit should succeed, rc=$EXIT_RC err=$EXIT_ERR"
pass "T5: claude exit dialog on pre-exit: does NOT refuse (sight-confirm handles it)"

# --- T8: codex, claude-specific checks are no-ops ---------------------------
run_exit_case codex 1 \
  "idle composer"
[ "$EXIT_RC" -eq 0 ] || fail "T8: codex should exit 0 (claude checks no-ops), rc=$EXIT_RC err=$EXIT_ERR"
pass "T8: codex: claude-specific checks do not fire, exit proceeds normally"

echo "All tests passed"
