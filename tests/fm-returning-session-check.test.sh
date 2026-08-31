#!/usr/bin/env bash
# tests/fm-returning-session-check.test.sh - behavior tests for
# bin/fm-returning-session-check.sh. Exercises the helper only through its
# executable interface: a session whose last context reading is below the
# restart band must verdict=resume, one at or past the restart band must
# verdict=restart-with-carryover, and a home with no transcript yet must
# verdict=unknown rather than forcing a restart on missing evidence.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../bin/fm-returning-session-check.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mk_line() {
  # mk_line <input> <cache_create> <cache_read>
  printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":%d,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d,"output_tokens":10,"server_tool_use":{"web_search_requests":0}}}}\n' \
    "$1" "$2" "$3"
}

mk_home() {
  # mk_home <home-dir> <total-tokens>
  home="$1"
  total="$2"
  mkdir -p "$home"
  munged="$(printf '%s' "$home" | tr -c 'a-zA-Z0-9' '-')"
  proj="$tmp/claude_home/.claude/projects/$munged"
  mkdir -p "$proj"
  mk_line 2 0 "$((total - 2))" > "$proj/session.jsonl"
}

# 1. A returning session below the restart band resumes bare.
warn_home="$tmp/warm_home"
mk_home "$warn_home" 50000
out="$(HOME="$tmp/claude_home" "$bin" "$warn_home")"
case "$out" in
  *"verdict=resume band=ok "*) ;;
  *) fail "expected verdict=resume band=ok, got: $out" ;;
esac

# 2. A returning session at or past the default restart band (250000) must
#    get a carryover-restart verdict, not a bare resume.
hot_home="$tmp/hot_home"
mk_home "$hot_home" 260000
out="$(HOME="$tmp/claude_home" "$bin" "$hot_home")"
case "$out" in
  *"verdict=restart-with-carryover band=restart "*) ;;
  *) fail "expected verdict=restart-with-carryover band=restart, got: $out" ;;
esac
case "$out" in
  *"context_tokens=260000 restart_tokens=250000 "*) ;;
  *) fail "expected context/restart token fields passed through, got: $out" ;;
esac

# 3. A home-local config/context-thresholds override is honored, matching
#    fm-context-usage.sh's own resolution.
cfg_home="$tmp/cfg_home"
mk_home "$cfg_home" 60000
mkdir -p "$cfg_home/config"
printf 'warn=10000\nrestart=50000\n' > "$cfg_home/config/context-thresholds"
out="$(HOME="$tmp/claude_home" "$bin" "$cfg_home")"
case "$out" in
  *"verdict=restart-with-carryover band=restart "*"restart_tokens=50000 "*) ;;
  *) fail "expected local threshold override to force restart-with-carryover, got: $out" ;;
esac

# 4. A home with no transcript yet is unknown, not restart-with-carryover.
absent_home="$tmp/absent_home"
mkdir -p "$absent_home"
out="$(HOME="$tmp/claude_home" "$bin" "$absent_home")"
case "$out" in
  verdict=unknown\ reason=*) ;;
  *) fail "expected verdict=unknown for a transcript-free home, got: $out" ;;
esac

# 5. Wrong argument count fails loudly rather than guessing a home.
if "$bin" 2>"$tmp/err"; then
  fail "expected failure with no argument"
fi
grep -q "usage:" "$tmp/err" || fail "missing usage message on bad invocation"

if "$bin" "$warn_home" extra 2>"$tmp/err2"; then
  fail "expected failure with too many arguments"
fi
grep -q "usage:" "$tmp/err2" || fail "missing usage message on extra argument"

echo "ok: fm-returning-session-check.test.sh"
