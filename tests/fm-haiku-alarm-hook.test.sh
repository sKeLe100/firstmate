#!/usr/bin/env bash
# tests/fm-haiku-alarm-hook.test.sh - behavior tests for bin/fm-haiku-alarm-hook.sh.
# Drives the hook only through its stdin/stdout interface with Claude-shaped hook
# JSON and a synthetic subagent transcript whose last usage row sets the context
# size. Covers the six section-5 item-2 acceptance cases (79,999 / 80,000 /
# 94,999 / 95,000 deny / 95,000 checkpoint-write allow / no agent_id no-op), plus
# the PostToolUse lag estimate and malformed input.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hook="$ROOT/bin/fm-haiku-alarm-hook.sh"
tmp="$(mktemp -d)"
trap 'fm_test_remove_tree "$tmp"' EXIT

proj="$tmp/proj"
main="$proj/main.jsonl"
sub="$proj/sess-1/subagents/agent-ag1.jsonl"
checkpoint="$tmp/checkpoint.md"
mkdir -p "$proj/sess-1/subagents"
: > "$main"

# set_context <total>: the subagent's last assistant row carries <total> input
# tokens, so the reader reports exactly that context size.
set_context() {
  printf '{"type":"assistant","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":1000,"output_tokens":5}}}\n' > "$sub"
  printf '{"type":"assistant","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":%d,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}\n' "$1" >> "$sub"
}

# hook_in <event> <tool_name> <tool_input_json> [tool_response_json]
hook_in() {
  local event=$1 tool=$2 tin=$3 resp=${4:-} extra=""
  [ -n "$resp" ] && extra=",\"tool_response\":$resp"
  printf '{"session_id":"sess-1","transcript_path":"%s","cwd":"%s","hook_event_name":"%s","agent_id":"ag1","agent_type":"haiku-builder","tool_name":"%s","tool_input":%s%s}' \
    "$main" "$tmp" "$event" "$tool" "$tin" "$extra"
}

# run_hook <input-json>: sets OUT (stdout) and RC (exit code).
run_hook() {
  OUT="$(printf '%s' "$1" | FM_CHECKPOINT_PATH="$checkpoint" bash "$hook")"
  RC=$?
}

# field <json> <python-expression over d>: extracts one value from hook output.
field() {
  printf '%s' "$1" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$2"
}

bash_input='{"command":"ls"}'
write_checkpoint="{\"file_path\":\"$checkpoint\",\"content\":\"x\"}"
write_other="{\"file_path\":\"$tmp/other.md\",\"content\":\"x\"}"

# 1. 79,999 tokens on a PostToolUse: below the warn line, so nothing is printed.
set_context 79999
run_hook "$(hook_in PostToolUse Read '{"file_path":"x"}')"
[ "$RC" -eq 0 ] || fail "79,999 PostToolUse exited $RC"
[ -z "$OUT" ] || fail "79,999 PostToolUse should print nothing, got: $OUT"
pass "79,999 tokens prints nothing"

# 2. 80,000 tokens on a PostToolUse: the 80k warning as additionalContext.
set_context 80000
run_hook "$(hook_in PostToolUse Read '{"file_path":"x"}')"
[ "$RC" -eq 0 ] || fail "80,000 PostToolUse exited $RC"
[ "$(field "$OUT" 'd["hookSpecificOutput"]["hookEventName"]')" = "PostToolUse" ] \
  || fail "80,000 PostToolUse did not name the PostToolUse event: $OUT"
ctx="$(field "$OUT" 'd["hookSpecificOutput"]["additionalContext"]')"
case "$ctx" in
  "Context ~80k of a 100k price line."*) ;;
  *) fail "80,000 PostToolUse warning text is wrong: $ctx" ;;
esac
pass "80,000 tokens prints the 80k warning as PostToolUse additionalContext"

# 3. 94,999 tokens on a PostToolUse: still the warning band, not the stop.
set_context 94999
run_hook "$(hook_in PostToolUse Read '{"file_path":"x"}')"
ctx="$(field "$OUT" 'd["hookSpecificOutput"]["additionalContext"]' 2>/dev/null || true)"
case "$ctx" in
  "Context ~94k of a 100k price line."*) ;;
  *) fail "94,999 PostToolUse should warn with ~94k, got: $OUT" ;;
esac
pass "94,999 tokens stays in the warning band"

# 4. 95,000 tokens on a PreToolUse: a deny with the 95k stop reason.
set_context 95000
run_hook "$(hook_in PreToolUse Bash "$bash_input")"
[ "$RC" -eq 0 ] || fail "95,000 PreToolUse exited $RC"
[ "$(field "$OUT" 'd["hookSpecificOutput"]["permissionDecision"]')" = "deny" ] \
  || fail "95,000 PreToolUse did not deny: $OUT"
reason="$(field "$OUT" 'd["hookSpecificOutput"]["permissionDecisionReason"]')"
case "$reason" in
  "95k: stop now, reply with checkpoint"*) ;;
  *) fail "95,000 deny reason is wrong: $reason" ;;
esac
pass "95,000 tokens denies a non-checkpoint tool call with the 95k reason"

# 5. 95,000 tokens: a Write to the checkpoint path is still allowed.
run_hook "$(hook_in PreToolUse Write "$write_checkpoint")"
[ "$RC" -eq 0 ] || fail "checkpoint write exited $RC"
[ -z "$OUT" ] || fail "a checkpoint write at 95,000 must be allowed, got: $OUT"
pass "95,000 tokens still allows a Write to FM_CHECKPOINT_PATH"

# 6. A Write to some other path at 95,000 is denied, so the exception is narrow.
run_hook "$(hook_in PreToolUse Write "$write_other")"
[ "$(field "$OUT" 'd["hookSpecificOutput"]["permissionDecision"]')" = "deny" ] \
  || fail "a non-checkpoint Write at 95,000 must be denied: $OUT"
pass "95,000 tokens denies a Write to any other path"

# 7. No agent_id: the call is not from a subagent, so the hook is a no-op even
#    at 95,000 tokens.
noagent='{"session_id":"sess-1","transcript_path":"'"$main"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}'
run_hook "$noagent"
[ "$RC" -eq 0 ] || fail "no-agent_id input exited $RC"
[ -z "$OUT" ] || fail "no agent_id must be a no-op, got: $OUT"
pass "no agent_id is a no-op"

# 8. PostToolUse lag: the tool result just returned is not in the transcript
#    yet, so its size (characters / 3) is added. 79,999 + a 6,000-character
#    result (2,000 estimated tokens) reaches 81,999, which must warn.
set_context 79999
big_response="\"$(python3 -c 'print("a" * 6000, end="")')\""
run_hook "$(hook_in PostToolUse Read '{"file_path":"x"}' "$big_response")"
ctx="$(field "$OUT" 'd["hookSpecificOutput"]["additionalContext"]' 2>/dev/null || true)"
case "$ctx" in
  "Context ~81k of a 100k price line."*) ;;
  *) fail "a 6,000-character result on 79,999 should warn at ~81k, got: $OUT" ;;
esac
pass "PostToolUse adds the just-returned result's estimate to the transcript figure"

# 9. PreToolUse does not add a result estimate; at 80,000 it prints nothing, the
#    warning belongs to PostToolUse.
set_context 80000
run_hook "$(hook_in PreToolUse Bash "$bash_input")"
[ -z "$OUT" ] || fail "80,000 PreToolUse should print nothing (warning is PostToolUse), got: $OUT"
pass "80,000 tokens on PreToolUse prints nothing"

# 10. Malformed hook input is loud (exit 1), never silently allowed.
rc=0
printf 'not json' | bash "$hook" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 1 ] || fail "malformed input should exit 1, got $rc"
grep -q "malformed hook input" "$tmp/err" || fail "malformed input did not name the cause"
pass "malformed hook input exits 1 with a named cause"
