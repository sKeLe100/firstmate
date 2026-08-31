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

# 4b. The other no-evidence-yet shapes stay unknown too: a project dir with no
#     transcript file, and a transcript with no assistant usage record.
empty_proj_home="$tmp/empty_proj_home"
mkdir -p "$empty_proj_home"
mkdir -p "$tmp/claude_home/.claude/projects/$(printf '%s' "$empty_proj_home" | tr -c 'a-zA-Z0-9' '-')"
out="$(HOME="$tmp/claude_home" "$bin" "$empty_proj_home")"
case "$out" in
  verdict=unknown\ reason=*) ;;
  *) fail "expected verdict=unknown for a home with no transcript file, got: $out" ;;
esac

no_usage_home="$tmp/no_usage_home"
mkdir -p "$no_usage_home"
no_usage_proj="$tmp/claude_home/.claude/projects/$(printf '%s' "$no_usage_home" | tr -c 'a-zA-Z0-9' '-')"
mkdir -p "$no_usage_proj"
printf '{"type":"user","message":{"content":"hi"}}\n' > "$no_usage_proj/session.jsonl"
out="$(HOME="$tmp/claude_home" "$bin" "$no_usage_home")"
case "$out" in
  verdict=unknown\ reason=*) ;;
  *) fail "expected verdict=unknown for a transcript with no usage record, got: $out" ;;
esac

# 5. A broken config/context-thresholds is a blocked verdict with a non-zero
#    exit, never an unknown that reads as safe to bare-resume.
bad_home="$tmp/bad_home"
mk_home "$bad_home" 60000
mkdir -p "$bad_home/config"
printf 'warn=not-a-number\n' > "$bad_home/config/context-thresholds"
if out="$(HOME="$tmp/claude_home" "$bin" "$bad_home")"; then
  fail "expected non-zero exit for a malformed thresholds config, got: $out"
fi
case "$out" in
  verdict=blocked\ reason=*) ;;
  *) fail "expected verdict=blocked for a malformed thresholds config, got: $out" ;;
esac

# 5b. An unclassified failure - here a config/context-thresholds that exists
#     but cannot be read - must fail safe as blocked, not open as unknown.
unreadable_home="$tmp/unreadable_home"
mk_home "$unreadable_home" 60000
mkdir -p "$unreadable_home/config"
printf 'warn=10000\nrestart=50000\n' > "$unreadable_home/config/context-thresholds"
chmod 000 "$unreadable_home/config/context-thresholds"
if [ -r "$unreadable_home/config/context-thresholds" ]; then
  echo "skip: running as a user that can read mode-000 files, skipping unreadable-config case" >&2
else
  if out="$(HOME="$tmp/claude_home" "$bin" "$unreadable_home")"; then
    fail "expected non-zero exit for an unreadable thresholds config, got: $out"
  fi
  case "$out" in
    verdict=blocked\ reason=*) ;;
    *) fail "expected verdict=blocked for an unreadable thresholds config, got: $out" ;;
  esac
fi
chmod 644 "$unreadable_home/config/context-thresholds"

# 6. A relative home path is a usage error, not a silent unknown, because
#    transcript directories are keyed on the absolute path.
rel_out=""
if rel_out="$( (cd "$tmp" && HOME="$tmp/claude_home" "$bin" "warm_home") 2>"$tmp/err_rel")"; then
  fail "expected failure for a relative home path, got: $rel_out"
fi
grep -q "must be absolute" "$tmp/err_rel" || fail "missing absolute-path error for relative home"

# 7. A nonexistent home is a usage error too.
if out="$("$bin" "$tmp/no_such_home" 2>"$tmp/err_missing")"; then
  fail "expected failure for a nonexistent home, got: $out"
fi
grep -q "not a directory" "$tmp/err_missing" || fail "missing not-a-directory error"

# 8. Wrong argument count fails loudly rather than guessing a home.
if "$bin" 2>"$tmp/err"; then
  fail "expected failure with no argument"
fi
grep -q "usage:" "$tmp/err" || fail "missing usage message on bad invocation"

if "$bin" "$warn_home" extra 2>"$tmp/err2"; then
  fail "expected failure with too many arguments"
fi
grep -q "usage:" "$tmp/err2" || fail "missing usage message on extra argument"

echo "ok: fm-returning-session-check.test.sh"
