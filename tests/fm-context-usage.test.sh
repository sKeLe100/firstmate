#!/usr/bin/env bash
# tests/fm-context-usage.test.sh - behavior tests for bin/fm-context-usage.sh.
# Exercises the helper only through its executable interface with synthetic
# transcript files: the reported total must be the last NON-sidechain
# assistant turn's input + cache_creation + cache_read sum, missing inputs
# must fail loudly, and auto-discovery must pick the newest transcript in the
# munged home directory.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../bin/fm-context-usage.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mk_line() {
  # mk_line <type> <sidechain:true|false> <input> <cache_create> <cache_read>
  printf '{"type":"%s","isSidechain":%s,"message":{"usage":{"input_tokens":%d,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d,"output_tokens":10,"server_tool_use":{"web_search_requests":0}}}}\n' \
    "$1" "$2" "$3" "$4" "$5"
}

# 1. Explicit path: last non-sidechain assistant usage wins; a later sidechain
#    turn and non-assistant lines must be ignored.
t="$tmp/session.jsonl"
{
  printf '{"type":"user","message":{"content":"hi"}}\n'
  mk_line assistant false 2 100 200
  mk_line assistant false 2 40000 30000
  mk_line assistant true 2 5 5
  printf 'not json at all\n'
} > "$t"
out="$("$bin" "$t")"
case "$out" in
  *"context_tokens=70002 "*) ;;
  *) fail "expected context_tokens=70002, got: $out" ;;
esac
case "$out" in
  *"window=1000000 "*"percent=7.0 "*) ;;
  *) fail "expected default window/percent, got: $out" ;;
esac

# 2. FM_CONTEXT_WINDOW overrides the percent base.
out="$(FM_CONTEXT_WINDOW=140004 "$bin" "$t")"
case "$out" in
  *"percent=50.0 "*) ;;
  *) fail "expected percent=50.0 under FM_CONTEXT_WINDOW, got: $out" ;;
esac

# 3. A transcript with no usable usage record fails loudly.
printf '{"type":"user","message":{"content":"hi"}}\n' > "$tmp/empty.jsonl"
if "$bin" "$tmp/empty.jsonl" 2>"$tmp/err"; then
  fail "expected failure on usage-free transcript"
fi
grep -q "no assistant usage record" "$tmp/err" || fail "missing loud no-usage message"

# 4. A missing transcript path fails loudly.
if "$bin" "$tmp/nope.jsonl" 2>"$tmp/err2"; then
  fail "expected failure on missing transcript"
fi
grep -q "not found" "$tmp/err2" || fail "missing loud not-found message"

# 5. Auto-discovery: newest *.jsonl in the munged home directory wins.
fake_home="$tmp/fm_home"
mkdir -p "$fake_home"
munged="$(printf '%s' "$fake_home" | tr -c 'a-zA-Z0-9' '-')"
proj="$tmp/claude_home/.claude/projects/$munged"
mkdir -p "$proj"
mk_line assistant false 2 10 10 > "$proj/old.jsonl"
mk_line assistant false 2 500 500 > "$proj/new.jsonl"
touch -d '1 hour ago' "$proj/old.jsonl"
out="$(HOME="$tmp/claude_home" FM_HOME="$fake_home" "$bin")"
case "$out" in
  *"context_tokens=1002 "*new.jsonl*) ;;
  *) fail "auto-discovery did not pick newest transcript: $out" ;;
esac

# 6. Absent transcript directory fails loudly under auto-discovery.
if HOME="$tmp/claude_home" FM_HOME="$tmp/other_home" "$bin" 2>"$tmp/err3"; then
  fail "expected failure when transcript directory is absent"
fi
grep -q "no Claude transcript directory" "$tmp/err3" || fail "missing loud absent-directory message"

# 7. Default bands: 70002 tokens is below the 150000 default warn threshold.
out="$(FM_HOME="$tmp/no_config_home" "$bin" "$t")"
case "$out" in
  *"warn_tokens=150000 restart_tokens=250000 band=ok "*) ;;
  *) fail "expected default thresholds and band=ok, got: $out" ;;
esac

# 8. Default warn band at/above 150000, restart band at/above 250000.
warn_t="$tmp/warn.jsonl"; mk_line assistant false 2 100000 60000 > "$warn_t"
out="$(FM_HOME="$tmp/no_config_home" "$bin" "$warn_t")"
case "$out" in
  *"band=warn "*) ;;
  *) fail "expected band=warn at 160002 tokens, got: $out" ;;
esac
over_t="$tmp/over.jsonl"; mk_line assistant false 2 200000 60000 > "$over_t"
out="$(FM_HOME="$tmp/no_config_home" "$bin" "$over_t")"
case "$out" in
  *"band=restart "*) ;;
  *) fail "expected band=restart at 260002 tokens, got: $out" ;;
esac

# 9. config/context-thresholds under FM_HOME overrides the defaults, including
#    with an explicit transcript argument.
cfg_home="$tmp/cfg_home"
mkdir -p "$cfg_home/config"
printf 'warn=50000\nrestart=65000\n' > "$cfg_home/config/context-thresholds"
out="$(FM_HOME="$cfg_home" "$bin" "$t")"
case "$out" in
  *"warn_tokens=50000 restart_tokens=65000 band=restart "*) ;;
  *) fail "expected configured thresholds and band=restart at 70002, got: $out" ;;
esac
printf 'restart=300000\n' > "$cfg_home/config/context-thresholds"
out="$(FM_HOME="$cfg_home" "$bin" "$t")"
case "$out" in
  *"warn_tokens=150000 restart_tokens=300000 band=ok "*) ;;
  *) fail "expected partial config to keep the other default, got: $out" ;;
esac

# 10. A malformed thresholds file is rejected loudly, never silently defaulted.
printf 'warn=abc\n' > "$cfg_home/config/context-thresholds"
if FM_HOME="$cfg_home" "$bin" "$t" 2>"$tmp/err4"; then
  fail "expected failure on malformed warn value"
fi
grep -q "malformed warn value" "$tmp/err4" || fail "missing loud malformed-warn message"
printf 'bogus line\n' > "$cfg_home/config/context-thresholds"
if FM_HOME="$cfg_home" "$bin" "$t" 2>"$tmp/err5"; then
  fail "expected failure on unrecognized config line"
fi
grep -q "unrecognized line" "$tmp/err5" || fail "missing loud unrecognized-line message"
printf 'warn=200000\nrestart=100000\n' > "$cfg_home/config/context-thresholds"
if FM_HOME="$cfg_home" "$bin" "$t" 2>"$tmp/err6"; then
  fail "expected failure when warn exceeds restart"
fi
grep -q "warn <= restart" "$tmp/err6" || fail "missing loud warn-exceeds-restart message"

# 11. context-thresholds must be in FM_INHERITABLE_CONFIG so the primary's
#     thresholds propagate to secondmate homes.
# shellcheck source=/dev/null
. "$here/../bin/fm-config-inherit-lib.sh"
case " $FM_INHERITABLE_CONFIG " in
  *" context-thresholds "*) ;;
  *) fail "config/context-thresholds must be in FM_INHERITABLE_CONFIG so secondmate homes inherit the thresholds" ;;
esac

echo "PASS fm-context-usage.test.sh"
