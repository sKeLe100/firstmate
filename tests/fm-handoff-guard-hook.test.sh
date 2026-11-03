#!/usr/bin/env bash
# tests/fm-handoff-guard-hook.test.sh - behavior tests for bin/fm-handoff-guard-hook.sh.
# Drives the PreToolUse hook only through stdin/stdout and FM_HANDOFF_LOG with
# Claude-shaped Agent hook JSON and small fixture files in the test temp dir.
# Covers the section-5 item-3 acceptance cases: an under-budget allow, an
# over-budget deny naming the biggest file, a missing FILES deny, a directory
# deny, a non-haiku launch left untouched, and exactly one log row per decision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hook="$ROOT/bin/fm-handoff-guard-hook.sh"
tmp="$(mktemp -d)"
trap 'fm_test_remove_tree "$tmp"' EXIT

work="$tmp/work"
mkdir -p "$work/subdir"
log="$tmp/handoff.jsonl"

printf 'small\n' > "$work/small.txt"
# 2,000 lines of 100 characters: about 66,700 estimated tokens in full, but only
# two lines (about 70 estimated tokens) when a path:1-2 range is given.
python3 -c 'print("\n".join("x" * 100 for _ in range(2000)))' > "$work/big.txt"

# mk_input <tool_name> <subagent_type|-> <model|-> <prompt>: Agent hook JSON.
mk_input() {
  python3 - "$1" "$2" "$3" "$4" "$work" <<'PY'
import json, sys
tool, sub, model, prompt, cwd = sys.argv[1:6]
tool_input = {"prompt": prompt}
if sub != "-":
    tool_input["subagent_type"] = sub
if model != "-":
    tool_input["model"] = model
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "tool_name": tool,
    "tool_input": tool_input,
    "cwd": cwd,
}))
PY
}

# run_guard <input-json>: sets OUT (stdout) and RC (exit code); logs to $log.
run_guard() {
  OUT="$(printf '%s' "$1" | FM_HANDOFF_LOG="$log" bash "$hook")"
  RC=$?
}

# field <json> <python-expression over d>: extracts one value from hook output.
field() {
  printf '%s' "$1" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$2"
}

# 1. Under budget: a small FILES list is allowed, with no output.
run_guard "$(mk_input Agent haiku-builder - $'Slice one.\nFILES:\n- small.txt')"
[ "$RC" -eq 0 ] || fail "under-budget launch exited $RC"
[ -z "$OUT" ] || fail "under-budget launch should be allowed silently, got: $OUT"
pass "an under-budget haiku-builder launch is allowed"

# 2. Over budget: a 66k-token file pushes the estimate past 70,000, and the deny
#    names that file as the biggest part.
run_guard "$(mk_input Agent haiku-builder - $'Slice two.\nFILES:\n- big.txt')"
[ "$(field "$OUT" 'd["hookSpecificOutput"]["permissionDecision"]')" = "deny" ] \
  || fail "over-budget launch was not denied: $OUT"
reason="$(field "$OUT" 'd["hookSpecificOutput"]["permissionDecisionReason"]')"
case "$reason" in
  *"over the 70000 budget"*"file:big.txt"*) ;;
  *) fail "over-budget deny did not name the biggest file and budget: $reason" ;;
esac
pass "an over-budget launch is denied and names the biggest file"

# 3. A line range counts only those lines, so the same big file under 1-2 fits.
run_guard "$(mk_input Agent haiku-builder - $'Slice three.\nFILES:\n- big.txt:1-2')"
[ -z "$OUT" ] || fail "a 1-2 line range of big.txt should fit the budget, got: $OUT"
pass "a path:START-END range counts only the named lines"

# 4. Missing FILES block: denied.
run_guard "$(mk_input Agent haiku-builder - 'Slice four, no file list.')"
reason="$(field "$OUT" 'd["hookSpecificOutput"]["permissionDecisionReason"]')"
case "$reason" in
  *"no FILES: block"*) ;;
  *) fail "a launch without FILES: must be denied naming the gap, got: $OUT" ;;
esac
pass "a launch without a FILES: block is denied"

# 5. A FILES entry that names a directory is denied.
run_guard "$(mk_input Agent haiku-builder - $'Slice five.\nFILES:\n- subdir/')"
reason="$(field "$OUT" 'd["hookSpecificOutput"]["permissionDecisionReason"]')"
case "$reason" in
  *"directory, not a file: subdir/"*) ;;
  *) fail "a directory FILES entry must be denied, got: $OUT" ;;
esac
pass "a FILES entry naming a directory is denied"

# 6. A non-haiku launch is untouched: no output and no log row, even with no
#    FILES block.
run_guard "$(mk_input Agent general-purpose sonnet 'not a haiku launch')"
[ "$RC" -eq 0 ] || fail "non-haiku launch exited $RC"
[ -z "$OUT" ] || fail "a non-haiku launch must be untouched, got: $OUT"
pass "a non-haiku Agent launch is untouched"

# 7. model haiku without a subagent_type is still guarded.
run_guard "$(mk_input Agent - haiku $'Slice seven.\nFILES:\n- small.txt')"
[ -z "$OUT" ] || fail "a model=haiku launch with a small FILES list should be allowed: $OUT"
pass "model haiku with no subagent_type is also guarded"

# 8. A non-Agent tool is untouched and logs nothing.
run_guard "$(mk_input Bash - - 'echo hi')"
[ -z "$OUT" ] || fail "a non-Agent tool must be untouched, got: $OUT"
pass "a non-Agent tool is untouched"

# 9. Exactly one log row per guarded decision, in launch order: allow (small),
#    deny (big), allow (range), deny (no FILES), deny (directory), allow
#    (model=haiku). The untouched non-haiku and non-Agent calls add no rows.
rows="$(wc -l < "$log")"
[ "$rows" -eq 6 ] || fail "expected exactly 6 log rows (one per guarded decision), got $rows"
decisions="$(python3 -c '
import json, sys
print(",".join(json.loads(line)["decision"] for line in open(sys.argv[1])))
' "$log")"
[ "$decisions" = "allow,deny,allow,deny,deny,allow" ] \
  || fail "log decisions out of order or wrong: $decisions"
pass "exactly one JSONL log row per guarded decision, in order"
