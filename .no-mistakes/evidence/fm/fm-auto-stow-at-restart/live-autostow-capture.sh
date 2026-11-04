#!/usr/bin/env bash
# Capture the exact auto-stow feedback in a real Claude transcript, and drive the
# real Stop hook at the captain's exact 374999/375000 boundary through a fake
# harness named claude (the product hook itself is unmodified).
set -u

RUN={run-worktree}
EV=~/.no-mistakes/evidence/01M6HFD4A3K5S249HXKN6D30YR
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() {
  if [ -n "${LAB:-}" ] && [ -d "$LAB" ]; then
    rm -rf "$LAB"
    echo "lab removed: $LAB"
  fi
}
trap cleanup EXIT

cd "$RUN" || exit 1
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
git -C "$LAB" init -q
git -C "$LAB" -c user.email=fmtest@example.invalid -c user.name=fmtest \
  commit -q --allow-empty -m init
: > "$LAB/AGENTS.md"
ln -s "$RUN/bin" "$LAB/bin"
mkdir -p "$LAB/.claude"
cp "$RUN/.claude/settings.json" "$LAB/.claude/settings.json"

echo "=================== wake capture + boundary drive $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "lab home: $LAB"

printf 'warn=500\nrestart=1000\n' > "$LAB/config/context-thresholds"
echo
echo "=== S1 real Claude session at the restart band"
out="$LAB/wake.out"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" bash -c 'cd "$FM_HOME" || exit 1
      echo $$ > "$FM_HOME/state/.lock"
      exec claude -p "Reply with exactly: FIRST" --dangerously-skip-permissions \
        --effort low --settings "{\"feedbackDrafts\":\"off\"}"' \
    </dev/null >"$out" 2>&1
echo "claude rc=$?"
tail -n 8 "$out" | sed 's/^/  assistant: /'
munged=$(printf '%s' "$LAB" | tr -c 'a-zA-Z0-9' '-')
proj="$HOME/.claude/projects/$munged"
transcript=$(find "$proj" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
echo "transcript: $transcript"
[ -n "$transcript" ] && cp "$transcript" "$EV/claude-autostow-session.jsonl"
echo "markers:"
find "$LAB/state" -maxdepth 1 -name '.auto-stow-*' -printf '  %f\n' 2>/dev/null | sort
if [ -n "$transcript" ]; then
  echo "auto-stow feedback records in the real session transcript:"
  jq -c 'select((tostring) | contains("firstmate auto-stow"))' "$transcript" 2>/dev/null \
    | head -4 | sed 's/^/  /'
fi

echo
echo "=== Synthetic boundary drive through the same real Stop hook"
FAKE="$LAB/fakebin/claude"
mkdir -p "$LAB/fakebin"
ln -s /bin/bash "$FAKE"
printf 'warn=250000\nrestart=375000\n' > "$LAB/config/context-thresholds"
write_transcript() {
  printf '{"type":"user","message":{"content":"hi"}}\n' > "$1"
  printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":%d,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}\n' "$2" >> "$1"
}
write_transcript "$LAB/below.jsonl" 374999
write_transcript "$LAB/at.jsonl" 375000
echo "helper 374999: $(FM_HOME="$LAB" "$RUN/bin/fm-context-usage.sh" "$LAB/below.jsonl" 2>&1)"
echo "helper 375000: $(FM_HOME="$LAB" "$RUN/bin/fm-context-usage.sh" "$LAB/at.jsonl" 2>&1)"

run_stop() {  # <label> <sid> <transcript>
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
run_stop S7-below-restart sess-below-374999 "$LAB/below.jsonl"
run_stop S8-at-restart sess-at-375000 "$LAB/at.jsonl"
echo "=== done $(date -u +%Y-%m-%dT%H:%M:%SZ)"
