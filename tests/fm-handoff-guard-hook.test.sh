#!/usr/bin/env bash
# tests/fm-handoff-guard-hook.test.sh - behavior tests for bin/fm-handoff-guard-hook.sh.
# Drives the PreToolUse hook only through stdin/stdout and FM_HANDOFF_LOG with
# Claude-shaped Agent hook JSON and small fixture files in the test temp dir.
# Covers the section-5 item-3 acceptance cases: an under-budget allow, an
# over-budget deny naming the biggest file, a missing FILES deny, a directory
# deny, a non-haiku launch left untouched, and exactly one log row per decision.
# Also covers FILES formatting variants, malformed ranges, a to-be-created path,
# and a log failure that must not suppress a deny.
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

# run_guard_log <input-json> <log-path>: sets OUT (stdout) and RC (exit code).
run_guard_log() {
  OUT="$(printf '%s' "$1" | FM_HANDOFF_LOG="$2" bash "$hook")"
  RC=$?
}

# run_guard <input-json>: sets OUT (stdout) and RC (exit code); logs to $log.
run_guard() {
  run_guard_log "$1" "$log"
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

# 10. Recognized bullet styles and blank lines inside the block count the file,
#     so no over-budget launch slips through on a formatting variant. Malformed
#     ranges and an empty block are their own denials.
variants_log="$tmp/variants.jsonl"
assert_variant_denies() {  # <name> <prompt> <expected-reason-substring>
  local name=$1 prompt=$2 expected=$3 reason
  run_guard_log "$(mk_input Agent haiku-builder - "$prompt")" "$variants_log"
  [ -n "$OUT" ] || fail "FILES variant '$name' was allowed without a decision"
  [ "$(field "$OUT" 'd["hookSpecificOutput"]["permissionDecision"]')" = "deny" ] \
    || fail "FILES variant '$name' was not denied: $OUT"
  reason="$(field "$OUT" 'd["hookSpecificOutput"]["permissionDecisionReason"]')"
  case "$reason" in
    *"$expected"*) ;;
    *) fail "FILES variant '$name' deny reason missing '$expected': $reason" ;;
  esac
}
assert_variant_denies "star bullet" $'Slice.\nFILES:\n* big.txt' "file:big.txt"
assert_variant_denies "plus bullet" $'Slice.\nFILES:\n+ big.txt' "file:big.txt"
assert_variant_denies "numbered bullet" $'Slice.\nFILES:\n1. big.txt' "file:big.txt"
assert_variant_denies "blank line before the first entry" $'Slice.\nFILES:\n\n- big.txt' "file:big.txt"
assert_variant_denies "blank line between entries" $'Slice.\nFILES:\n- small.txt\n\n- big.txt' "file:big.txt"
assert_variant_denies "incomplete range" $'Slice.\nFILES:\n- big.txt:1-' "incomplete line range"
assert_variant_denies "range starting at zero" $'Slice.\nFILES:\n- big.txt:0-1500' "invalid line range"
assert_variant_denies "reversed range" $'Slice.\nFILES:\n- big.txt:5-2' "invalid line range"
assert_variant_denies "empty FILES block" $'Slice.\nFILES:' "no FILES: block"
pass "FILES formatting variants are parsed or denied, never silently undercounted"

# 11. An unresolved FILES path is the documented "file to create" case and
#     counts 0, so a small creation stays under budget and logs that zero.
create_log="$tmp/create.jsonl"
run_guard_log "$(mk_input Agent haiku-builder - $'Slice eleven.\nFILES:\n- new-file.txt')" "$create_log"
[ -z "$OUT" ] || fail "a to-be-created file under budget should be allowed: $OUT"
if ! python3 - "$create_log" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
if not rows:
    sys.exit("no log row for the to-be-created file")
parts = {part["name"]: part["tokens"] for part in rows[-1]["parts"]}
if rows[-1]["decision"] != "allow" or parts.get("file:new-file.txt") != 0:
    sys.exit("expected allow with file:new-file.txt at 0 tokens, got %r" % rows[-1])
PY
then
  fail "a missing FILES path is not treated as a 0-token file to create"
fi
pass "an unresolved FILES path counts 0 as a file to create"

# 12. A log path that cannot be created warns on stderr but never suppresses
#     the decision, so an over-budget launch is still denied.
printf 'blocker\n' > "$tmp/blocker"
bad_log="$tmp/blocker/nested/handoff.jsonl"
RC=0
OUT="$(printf '%s' "$(mk_input Agent haiku-builder - $'Slice twelve.\nFILES:\n- big.txt')" \
  | FM_HANDOFF_LOG="$bad_log" bash "$hook" 2>"$tmp/log.err")" || RC=$?
[ "$RC" -eq 0 ] || fail "an unwritable log turned the decision into exit $RC"
[ "$(field "$OUT" 'd["hookSpecificOutput"]["permissionDecision"]')" = "deny" ] \
  || fail "an unwritable log suppressed the deny: $OUT"
grep -q "could not append to FM_HANDOFF_LOG" "$tmp/log.err" \
  || fail "an unwritable log did not warn on stderr: $(cat "$tmp/log.err")"
pass "a log failure warns but still emits the deny"

# 13. A FILES entry that exists but cannot be read must not abort before the
#     decision: an unreadable whole-file entry is sized, and an unreadable range
#     entry is denied, each with exactly one log row.
if [ "$(id -u)" = 0 ]; then
  printf '# skip - unreadable FILES fixture requires a non-root user\n'
else
  secret="$work/secret.txt"
  python3 -c 'print("s" * 500)' > "$secret"
  chmod 000 "$secret"
  unreadable_log="$tmp/unreadable.jsonl"
  RC=0
  OUT="$(printf '%s' "$(mk_input Agent haiku-builder - $'Slice thirteen.\nFILES:\n- big.txt\n- secret.txt')" \
    | FM_HANDOFF_LOG="$unreadable_log" bash "$hook" 2>"$tmp/unreadable.err")" || RC=$?
  [ "$RC" -eq 0 ] || fail "an unreadable whole-file entry aborted with exit $RC: $(cat "$tmp/unreadable.err")"
  [ "$(field "$OUT" 'd["hookSpecificOutput"]["permissionDecision"]')" = "deny" ] \
    || fail "an unreadable whole-file entry suppressed the over-budget deny: $OUT"
  rows="$(wc -l < "$unreadable_log")"
  [ "$rows" -eq 1 ] || fail "an unreadable whole-file entry logged $rows rows, expected 1"
  pass "an unreadable whole-file entry is sized without aborting the deny"

  range_log="$tmp/unreadable-range.jsonl"
  RC=0
  OUT="$(printf '%s' "$(mk_input Agent haiku-builder - $'Slice thirteen.\nFILES:\n- secret.txt:1-1')" \
    | FM_HANDOFF_LOG="$range_log" bash "$hook" 2>"$tmp/unreadable-range.err")" || RC=$?
  [ "$RC" -eq 0 ] || fail "an unreadable range entry aborted with exit $RC: $(cat "$tmp/unreadable-range.err")"
  [ "$(field "$OUT" 'd["hookSpecificOutput"]["permissionDecision"]')" = "deny" ] \
    || fail "an unreadable range entry was allowed: $OUT"
  reason="$(field "$OUT" 'd["hookSpecificOutput"]["permissionDecisionReason"]')"
  case "$reason" in
    *"cannot be read"*"secret.txt:1-1"*) ;;
    *) fail "an unreadable range entry did not name the entry: $reason" ;;
  esac
  rows="$(wc -l < "$range_log")"
  [ "$rows" -eq 1 ] || fail "an unreadable range entry logged $rows rows, expected 1"
  chmod 600 "$secret"
  pass "an unreadable range entry is denied with its reason and one log row"
fi
