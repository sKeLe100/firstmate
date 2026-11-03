#!/usr/bin/env bash
# tests/fm-subagent-context.test.sh - behavior tests for bin/fm-subagent-context.sh.
# Exercises the reader only through its executable interface with synthetic
# subagent transcripts: the reported total is the LAST assistant usage row's
# input + cache_creation + cache_read sum (sidechain rows included), and a
# missing, unreadable, or usage-free file, and a crafted identifier each fail
# loudly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

reader="$ROOT/bin/fm-subagent-context.sh"
tmp="$(mktemp -d)"
trap 'fm_test_remove_tree "$tmp"' EXIT

main="$tmp/proj/main.jsonl"
sub_dir="$tmp/proj/sess-1/subagents"
mkdir -p "$sub_dir"
: > "$main"
sub="$sub_dir/agent-ag1.jsonl"

# 1. Usage totals 10k / 50k / 90k across three assistant rows: the last sum
#    (90000) is reported, with the model of that same row.
{
  printf '{"type":"user","message":{"content":"brief"}}\n'
  printf '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-5-5","usage":{"input_tokens":10000,"output_tokens":5}}}\n'
  printf '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-5-5","usage":{"input_tokens":50000,"output_tokens":5}}}\n'
  printf 'partial line with no json\n'
  printf '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-5-5","usage":{"input_tokens":60000,"cache_creation_input_tokens":10000,"cache_read_input_tokens":20000,"output_tokens":5}}}\n'
} > "$sub"
out="$("$reader" "$main" sess-1 ag1)" || fail "reader failed on a valid subagent transcript"
[ "$out" = "context_tokens=90000 agent=ag1 model=claude-haiku-5-5" ] \
  || fail "expected context_tokens=90000 for the 10k/50k/90k transcript, got: $out"
pass "reports the last assistant usage sum (90000) with its model"

# 2. The last row wins even when an earlier row was larger: a later smaller
#    turn means the subagent's context actually shrank.
{
  printf '{"type":"assistant","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":90000,"output_tokens":5}}}\n'
  printf '{"type":"assistant","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":40000,"output_tokens":5}}}\n'
} > "$sub"
out="$("$reader" "$main" sess-1 ag1)" || fail "reader failed on a shrinking transcript"
case "$out" in
  "context_tokens=40000 "*) ;;
  *) fail "expected the last row (40000), not the largest, got: $out" ;;
esac
pass "uses the last assistant row, not the largest earlier row"

# 3. A missing subagent file fails loudly with one clear line.
rc=0
err="$("$reader" "$main" sess-1 nope 2>&1 >/dev/null)" || rc=$?
[ "$rc" -eq 1 ] || fail "expected exit 1 for a missing subagent file, got $rc"
case "$err" in
  *"no subagent transcript"*) ;;
  *) fail "missing-file error did not name the cause: $err" ;;
esac
pass "missing subagent file exits 1 with a clear line"

# 4. An existing but unreadable subagent file also exits 1 with a clear line
#    instead of an unhandled read error.
if [ "$(id -u)" = 0 ]; then
  printf '# skip - unreadable transcript fixture requires a non-root user\n'
else
  unreadable="$sub_dir/agent-ag4.jsonl"
  printf '{"type":"assistant","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":50000}}}\n' > "$unreadable"
  chmod 000 "$unreadable"
  rc=0
  err="$("$reader" "$main" sess-1 ag4 2>&1 >/dev/null)" || rc=$?
  [ "$rc" -eq 1 ] || fail "expected exit 1 for an unreadable subagent file, got $rc"
  case "$err" in
    *"cannot read subagent transcript"*) ;;
    *) fail "unreadable-file error did not name the cause: $err" ;;
  esac
  case "$err" in
    *Traceback*) fail "unreadable-file error printed a traceback: $err" ;;
  esac
  chmod 600 "$unreadable"
  pass "unreadable subagent file exits 1 with a clear line"
fi

# 5. A subagent file that exists but has no usage row yet exits 3, distinct
#    from the missing-file exit 1, and still fails loudly with no zero.
printf '{"type":"user","message":{"content":"brief"}}\n' > "$sub_dir/agent-ag2.jsonl"
rc=0
err="$("$reader" "$main" sess-1 ag2 2>&1 >/dev/null)" || rc=$?
[ "$rc" -eq 3 ] || fail "expected exit 3 for a usage-free subagent file, got $rc"
case "$err" in
  *"no assistant usage row"*) ;;
  *) fail "usage-free error did not name the cause: $err" ;;
esac
pass "usage-free subagent file exits 3 instead of reporting zero"

# 6. A session or agent id that is not a plain identifier is refused (exit 2),
#    so a crafted id cannot walk out of the subagents directory.
rc=0
"$reader" "$main" sess-1 '../ag1' >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 for a traversal agent id, got $rc"
rc=0
"$reader" "$main" sess-1 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 for a missing argument, got $rc"
pass "refuses crafted identifiers and wrong arity with exit 2"
