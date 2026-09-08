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

# 9. idle_seconds reports "unknown" and never affects the verdict when
#    state-dir/task-id are omitted, even at warn band.
warn_band_home="$tmp/warn_band_home"
mk_home "$warn_band_home" 160000
out="$(HOME="$tmp/claude_home" "$bin" "$warn_band_home")"
case "$out" in
  *"verdict=resume band=warn "*"idle_seconds=unknown "*) ;;
  *) fail "expected verdict=resume band=warn with idle_seconds=unknown, got: $out" ;;
esac

# 10. A warn-band session idle past its TTL gets restart-with-carryover, not
#     a bare resume, even though context alone stays under the restart band.
idle_state="$tmp/idle_state"
mkdir -p "$idle_state"
now=$(date +%s)
touch -d "@$((now - 4000))" "$idle_state/coldtask.status"
idle_home="$tmp/idle_home"
mk_home "$idle_home" 160000
out="$(HOME="$tmp/claude_home" "$bin" "$idle_home" "$idle_state" coldtask)"
case "$out" in
  *"verdict=restart-with-carryover band=warn "*) ;;
  *) fail "expected verdict=restart-with-carryover band=warn for a cold idle warn-band session, got: $out" ;;
esac
case "$out" in
  *" ttl_seconds=3600 "*) ;;
  *) fail "expected ttl_seconds=3600 field, got: $out" ;;
esac
idle_field="$(printf '%s\n' "$out" | grep -o 'idle_seconds=[0-9]*' | cut -d= -f2)"
[ -n "$idle_field" ] && [ "$idle_field" -ge 4000 ] && [ "$idle_field" -le 4005 ] \
  || fail "expected idle_seconds near 4000, got: $out"

# 11. A warn-band session that is still within its TTL resumes bare.
warm_state="$tmp/warm_state"
mkdir -p "$warm_state"
touch -d "@$((now - 100))" "$warm_state/warmtask.status"
out="$(HOME="$tmp/claude_home" "$bin" "$warn_band_home" "$warm_state" warmtask)"
case "$out" in
  *"verdict=resume band=warn "*) ;;
  *) fail "expected verdict=resume band=warn for a warn-band session still within TTL, got: $out" ;;
esac

# 12. band=ok never restarts on idle alone, no matter how cold.
ancient_state="$tmp/ancient_state"
mkdir -p "$ancient_state"
touch -d "@$((now - 999999))" "$ancient_state/oldtask.status"
out="$(HOME="$tmp/claude_home" "$bin" "$warn_home" "$ancient_state" oldtask)"
case "$out" in
  *"verdict=resume band=ok "*) ;;
  *) fail "expected verdict=resume band=ok regardless of idle time, got: $out" ;;
esac

# 13. band=restart still restarts even when idle is well within TTL - context
#     size alone remains sufficient, matching the pre-existing behavior.
recent_state="$tmp/recent_state"
mkdir -p "$recent_state"
touch -d "@$((now - 10))" "$recent_state/hottask.status"
out="$(HOME="$tmp/claude_home" "$bin" "$hot_home" "$recent_state" hottask)"
case "$out" in
  *"verdict=restart-with-carryover band=restart "*) ;;
  *) fail "expected verdict=restart-with-carryover band=restart regardless of idle time, got: $out" ;;
esac

# 14. No readable activity marker under the given state-dir/task-id is
#     idle_seconds=unknown, not a crash or a forced restart.
empty_state="$tmp/empty_state"
mkdir -p "$empty_state"
out="$(HOME="$tmp/claude_home" "$bin" "$warn_band_home" "$empty_state" notask)"
case "$out" in
  *"verdict=resume band=warn "*"idle_seconds=unknown "*) ;;
  *) fail "expected idle_seconds=unknown with no activity marker, got: $out" ;;
esac

# 15. A cache-ttl-seconds override in the caller home's config/ (the config
#     directory beside the given state-dir) is honored, matching how every
#     other consumer of fm-cache-ttl-lib.sh reads that knob.
ttl_cfg_home="$tmp/ttl_cfg_home"
mk_home "$ttl_cfg_home" 160000
ttl_caller="$tmp/ttl_caller"
mkdir -p "$ttl_caller/config"
printf '500\n' > "$ttl_caller/config/cache-ttl-seconds"
ttl_state="$ttl_caller/state"
mkdir -p "$ttl_state"
touch -d "@$((now - 600))" "$ttl_state/ttltask.status"
out="$(HOME="$tmp/claude_home" "$bin" "$ttl_cfg_home" "$ttl_state" ttltask)"
case "$out" in
  *"verdict=restart-with-carryover band=warn "*"ttl_seconds=500 "*) ;;
  *) fail "expected local TTL override to force restart-with-carryover, got: $out" ;;
esac

# 16. Two arguments (state-dir without task-id, or vice versa) is a usage
#     error rather than a silent partial read.
if "$bin" "$warn_home" "$idle_state" 2>"$tmp/err_two"; then
  fail "expected failure for exactly two arguments"
fi
grep -q "usage:" "$tmp/err_two" || fail "missing usage message for two-argument call"

echo "ok: fm-returning-session-check.test.sh"
