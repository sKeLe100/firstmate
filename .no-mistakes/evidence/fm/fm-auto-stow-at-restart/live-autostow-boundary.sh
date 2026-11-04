#!/usr/bin/env bash
# Drive the real Stop hook at the captain's exact 374999/375000 boundary under a
# fake harness named claude that holds the lab home's session lock.
set -u
RUN={run-worktree}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() { [ -n "${LAB:-}" ] && rm -rf "$LAB" && echo "lab removed: $LAB"; }
trap cleanup EXIT
cd "$RUN" || exit 1
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
git -C "$LAB" init -q
git -C "$LAB" -c user.email=fmtest@example.invalid -c user.name=fmtest \
  commit -q --allow-empty -m init
: > "$LAB/AGENTS.md"
ln -s "$RUN/bin" "$LAB/bin"
mkdir -p "$LAB/fakebin"
FAKE="$LAB/fakebin/claude"
ln -s /bin/bash "$FAKE"
printf 'warn=250000\nrestart=375000\n' > "$LAB/config/context-thresholds"
write_transcript() {
  printf '{"type":"user","message":{"content":"hi"}}\n' > "$1"
  printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":%d,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}\n' "$2" >> "$1"
}
write_transcript "$LAB/below.jsonl" 374999
write_transcript "$LAB/at.jsonl" 375000
echo "=================== boundary drive $(date -u +%Y-%m-%dT%H:%M:%SZ) lab=$LAB"
echo "helper 374999: $(FM_HOME="$LAB" "$RUN/bin/fm-context-usage.sh" "$LAB/below.jsonl" 2>&1)"
echo "helper 375000: $(FM_HOME="$LAB" "$RUN/bin/fm-context-usage.sh" "$LAB/at.jsonl" 2>&1)"
run_stop() {
  local label=$1 sid=$2 transcript=$3 payload="$LAB/$1.payload" err="$LAB/$1.err" rc=0
  printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}\n' \
    "$sid" "$transcript" > "$payload"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
      -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
      -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$LAB" "$FAKE" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; "$FM_HOME/bin/fm-claude-stop-autoarm.sh"; exit $?' \
      <"$payload" >/dev/null 2>"$err" || rc=$?
  echo "=== $label (session $sid): hook rc=$rc marker=$([ -e "$LAB/state/.auto-stow-$sid" ] && echo yes || echo no)"
  sed 's/^/  stderr: /' "$err"
}
run_stop below-restart sess-below-374999 "$LAB/below.jsonl"
run_stop at-restart sess-at-375000 "$LAB/at.jsonl"
run_stop same-session-again sess-at-375000 "$LAB/at.jsonl"
echo "=== markers:"; find "$LAB/state" -maxdepth 1 -name '.auto-stow-*' -printf '  %f\n' | sort
echo "=== done $(date -u +%Y-%m-%dT%H:%M:%SZ)"
