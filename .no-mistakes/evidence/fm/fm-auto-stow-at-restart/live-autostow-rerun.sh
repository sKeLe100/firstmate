#!/usr/bin/env bash
# Live drive of the restart-band auto-stow change at HEAD. Runs the real
# installed Claude Code CLI (machine login) against a disposable marked lab
# home whose bin/ resolves to the run worktree, then drives the real Stop hook
# with synthetic boundary transcripts for exact 250k/375k threshold checks.
set -u

RUN={run-worktree}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")

cleanup() {
  if [ -n "${LAB:-}" ] && [ -d "$LAB" ]; then
    rm -rf "$LAB"
    echo "lab removed: $LAB"
  fi
}
trap cleanup EXIT

cd "$RUN" || exit 1
bin/fm-lab-home.sh create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
git -C "$LAB" init -q
git -C "$LAB" -c user.email=fmtest@example.invalid -c user.name=fmtest \
  commit -q --allow-empty -m init
: > "$LAB/AGENTS.md"
ln -s "$RUN/bin" "$LAB/bin"
mkdir -p "$LAB/.claude"
cp "$RUN/.claude/settings.json" "$LAB/.claude/settings.json"

echo "=================== live auto-stow re-drive $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "run worktree: $RUN"
echo "lab home:     $LAB"
echo "claude:       $(claude --version 2>&1 | head -1)"
echo "stop hook:    $LAB/bin/fm-claude-stop-autoarm.sh -> $RUN/bin/fm-claude-stop-autoarm.sh"

munged=$(printf '%s' "$LAB" | tr -c 'a-zA-Z0-9' '-')
proj="$HOME/.claude/projects/$munged"
newest_transcript() {
  find "$proj" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
}
markers() {
  find "$LAB/state" -maxdepth 1 -name '.auto-stow-*' -printf '%f\n' 2>/dev/null | sort
}
wake_count() {  # <transcript>
  [ -n "${1:-}" ] && [ -f "$1" ] || { echo 0; return; }
  jq -r 'select(.type == "user") | .message.content[]? | select(.type == "text") | .text' "$1" 2>/dev/null \
    | grep -c 'firstmate auto-stow' || true
}

# run_claude <label> <prompt> [continue]
run_claude() {
  local label=$1 prompt=$2 cont=${3:-} out="$LAB/$1.out"
  echo
  echo "=== $label"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
      -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
      -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$LAB" FM_PROMPT="$prompt" FM_CONT="$cont" \
      bash -c 'cd "$FM_HOME" || exit 1
               echo $$ > "$FM_HOME/state/.lock"
               exec claude $FM_CONT -p "$FM_PROMPT" --dangerously-skip-permissions \
                 --effort low --settings "{\"feedbackDrafts\":\"off\"}"' \
      </dev/null >"$out" 2>&1
  local rc=$?
  echo "claude rc=$rc"
  echo "assistant output (tail):"
  tail -n 12 "$out" | sed 's/^/  /'
  return "$rc"
}

# Synthetic Stop payload through the real hook, under a fake harness that holds
# the lock. Keeps the product hook and payload parsing real.
run_synthetic_stop() {  # <label> <session-id> <transcript>
  local label=$1 sid=$2 transcript=$3 payload="$LAB/$1.payload" err="$LAB/$1.err" rc=0
  printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}\n' \
    "$sid" "$transcript" > "$payload"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
      -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
      -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$LAB" bash -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; exec "$FM_HOME/bin/fm-claude-stop-autoarm.sh"' \
      <"$payload" >/dev/null 2>"$err" || rc=$?
  echo "=== $label (session $sid)"
  echo "hook rc=$rc"
  sed 's/^/  stderr: /' "$err"
  return 0
}

write_transcript() {  # <file> <context-tokens>
  printf '{"type":"user","message":{"content":"hi"}}\n' > "$1"
  printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":%d,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}\n' "$2" >> "$1"
}

printf 'warn=500\nrestart=1000\n' > "$LAB/config/context-thresholds"
echo
echo "=== thresholds for real-session restart checks: $(tr '\n' ' ' < "$LAB/config/context-thresholds")"

run_claude S1-restart-first 'Reply with exactly: FIRST'
t1=$(newest_transcript)
echo "transcript: $t1"
echo "wake entries: $(wake_count "$t1")"
echo "markers:"; markers | sed 's/^/  /'
echo "context read: $(FM_HOME="$LAB" "$RUN/bin/fm-context-usage.sh" "$t1" 2>&1)"

run_claude S2-same-session-resume 'Reply with exactly: SECOND' --continue
t2=$(newest_transcript)
echo "transcript: $t2"
echo "wake entries now: $(wake_count "$t2")"
echo "markers:"; markers | sed 's/^/  /'

run_claude S3-fresh-session 'Reply with exactly: THIRD'
t3=$(newest_transcript)
echo "transcript: $t3"
echo "wake entries now: $(wake_count "$t3")"
echo "markers:"; markers | sed 's/^/  /'

printf 'warn=1000\nrestart=40000\n' > "$LAB/config/context-thresholds"
echo
echo "=== thresholds for warn-band check: $(tr '\n' ' ' < "$LAB/config/context-thresholds")"
run_claude S4-warn-band 'Reply with exactly: WARNRUN'
t4=$(newest_transcript)
echo "transcript: $t4"
echo "wake entries now: $(wake_count "$t4")"
echo "markers:"; markers | sed 's/^/  /'
echo "context read: $(FM_HOME="$LAB" "$RUN/bin/fm-context-usage.sh" "$t4" 2>&1)"

printf 'warn=500\nrestart=1000\n' > "$LAB/config/context-thresholds"
: > "$LAB/config/auto-stow-off"
echo
echo "=== config/auto-stow-off present"
run_claude S5-off-switch 'Reply with exactly: OFFRUN'
t5=$(newest_transcript)
echo "wake entries now: $(wake_count "$t5")"
echo "markers:"; markers | sed 's/^/  /'
rm -f "$LAB/config/auto-stow-off"

: > "$LAB/state/.afk"
echo
echo "=== state/.afk present"
run_claude S6-afk 'Reply with exactly: AFKRUN'
t6=$(newest_transcript)
echo "wake entries now: $(wake_count "$t6")"
echo "markers:"; markers | sed 's/^/  /'
rm -f "$LAB/state/.afk"

echo
echo "=== captain thresholds 250k warn / 375k restart, exact boundaries through the real Stop hook"
printf 'warn=250000\nrestart=375000\n' > "$LAB/config/context-thresholds"
write_transcript "$LAB/below.jsonl" 374999
write_transcript "$LAB/at.jsonl" 375000
echo "helper at 374999: $(FM_HOME="$LAB" "$RUN/bin/fm-context-usage.sh" "$LAB/below.jsonl" 2>&1)"
echo "helper at 375000: $(FM_HOME="$LAB" "$RUN/bin/fm-context-usage.sh" "$LAB/at.jsonl" 2>&1)"
run_synthetic_stop S7-below-restart sess-below-374999 "$LAB/below.jsonl"
echo "markers:"; markers | sed 's/^/  /'
run_synthetic_stop S8-at-restart sess-at-375000 "$LAB/at.jsonl"
echo "markers:"; markers | sed 's/^/  /'

echo
echo "=== all auto-stow markers left in the lab state:"
markers | sed 's/^/  /'
echo "=== done $(date -u +%Y-%m-%dT%H:%M:%SZ)"
