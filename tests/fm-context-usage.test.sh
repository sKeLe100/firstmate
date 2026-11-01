#!/usr/bin/env bash
# tests/fm-context-usage.test.sh - behavior tests for bin/fm-context-usage.sh.
# Exercises the helper only through its executable interface with synthetic
# transcript files: the reported total must be the last NON-sidechain
# assistant turn's input + cache_creation + cache_read sum, missing inputs must
# fail loudly, a self-read must bind to the calling session's own transcript
# (or disclose that it fell back to the newest one), auto-discovery must read
# the session's own CLAUDE_CONFIG_DIR or the named target store, and a stale
# self-read must be refused while an explicit or targeted read is trusted.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../bin/fm-context-usage.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Every invocation runs without the harness session-identity variables a suite
# invoked from inside a Claude session would otherwise leak into these cases; a
# case that wants an id passes CLAUDE_CODE_SESSION_ID=... before the command.
scrubbed() { env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u HERDR_PANE_ID "$@"; }

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
out="$(scrubbed "$bin" "$t")"
case "$out" in
  *"context_tokens=70002 "*) ;;
  *) fail "expected context_tokens=70002, got: $out" ;;
esac
case "$out" in
  *"window=1000000 "*"percent=7.0 "*) ;;
  *) fail "expected default window/percent, got: $out" ;;
esac

# 2. FM_CONTEXT_WINDOW overrides the percent base.
out="$(FM_CONTEXT_WINDOW=140004 scrubbed "$bin" "$t")"
case "$out" in
  *"percent=50.0 "*) ;;
  *) fail "expected percent=50.0 under FM_CONTEXT_WINDOW, got: $out" ;;
esac

# 3. A transcript with no usable usage record fails loudly.
printf '{"type":"user","message":{"content":"hi"}}\n' > "$tmp/empty.jsonl"
if scrubbed "$bin" "$tmp/empty.jsonl" 2>"$tmp/err"; then
  fail "expected failure on usage-free transcript"
fi
grep -q "no assistant usage record" "$tmp/err" || fail "missing loud no-usage message"

# 4. A missing transcript path fails loudly.
if scrubbed "$bin" "$tmp/nope.jsonl" 2>"$tmp/err2"; then
  fail "expected failure on missing transcript"
fi
grep -q "not found" "$tmp/err2" || fail "missing loud not-found message"

# 5. Auto-discovery with no session id in the environment: the newest *.jsonl in
#    the munged home directory wins and the reading says it is not session-bound.
fake_home="$tmp/fm_home"
mkdir -p "$fake_home"
munged="$(printf '%s' "$fake_home" | tr -c 'a-zA-Z0-9' '-')"
proj="$tmp/claude_home/.claude/projects/$munged"
mkdir -p "$proj"
mk_line assistant false 2 10 10 > "$proj/old.jsonl"
mk_line assistant false 2 500 500 > "$proj/new.jsonl"
touch -d '1 hour ago' "$proj/old.jsonl"
out="$(CLAUDE_CONFIG_DIR='' HOME="$tmp/claude_home" FM_HOME="$fake_home" scrubbed "$bin")"
case "$out" in
  *"context_tokens=1002 "*new.jsonl*) ;;
  *) fail "auto-discovery did not pick newest transcript: $out" ;;
esac
case "$out" in
  *" pick=newest"*) ;;
  *) fail "an id-less self-read must report pick=newest, got: $out" ;;
esac

# 6. Absent transcript directory fails loudly under auto-discovery.
if CLAUDE_CONFIG_DIR='' HOME="$tmp/claude_home" FM_HOME="$tmp/other_home" scrubbed "$bin" 2>"$tmp/err3"; then
  fail "expected failure when transcript directory is absent"
fi
grep -q "no Claude transcript directory" "$tmp/err3" || fail "missing loud absent-directory message"

# 7. Default bands: 70002 tokens is below the 150000 default warn threshold.
out="$(FM_HOME="$tmp/no_config_home" scrubbed "$bin" "$t")"
case "$out" in
  *"warn_tokens=150000 restart_tokens=250000 band=ok "*) ;;
  *) fail "expected default thresholds and band=ok, got: $out" ;;
esac

# 8. Default warn band at/above 150000, restart band at/above 250000.
warn_t="$tmp/warn.jsonl"; mk_line assistant false 2 100000 60000 > "$warn_t"
out="$(FM_HOME="$tmp/no_config_home" scrubbed "$bin" "$warn_t")"
case "$out" in
  *"band=warn "*) ;;
  *) fail "expected band=warn at 160002 tokens, got: $out" ;;
esac
over_t="$tmp/over.jsonl"; mk_line assistant false 2 200000 60000 > "$over_t"
out="$(FM_HOME="$tmp/no_config_home" scrubbed "$bin" "$over_t")"
case "$out" in
  *"band=restart "*) ;;
  *) fail "expected band=restart at 260002 tokens, got: $out" ;;
esac

# 9. config/context-thresholds under FM_HOME overrides the defaults, including
#    with an explicit transcript argument.
cfg_home="$tmp/cfg_home"
mkdir -p "$cfg_home/config"
printf 'warn=50000\nrestart=65000\n' > "$cfg_home/config/context-thresholds"
out="$(FM_HOME="$cfg_home" scrubbed "$bin" "$t")"
case "$out" in
  *"warn_tokens=50000 restart_tokens=65000 band=restart "*) ;;
  *) fail "expected configured thresholds and band=restart at 70002, got: $out" ;;
esac
printf 'restart=300000\n' > "$cfg_home/config/context-thresholds"
out="$(FM_HOME="$cfg_home" scrubbed "$bin" "$t")"
case "$out" in
  *"warn_tokens=150000 restart_tokens=300000 band=ok "*) ;;
  *) fail "expected partial config to keep the other default, got: $out" ;;
esac

# 10. A malformed thresholds file is rejected loudly, never silently defaulted.
printf 'warn=abc\n' > "$cfg_home/config/context-thresholds"
if FM_HOME="$cfg_home" scrubbed "$bin" "$t" 2>"$tmp/err4"; then
  fail "expected failure on malformed warn value"
fi
grep -q "malformed warn value" "$tmp/err4" || fail "missing loud malformed-warn message"
printf 'bogus line\n' > "$cfg_home/config/context-thresholds"
if FM_HOME="$cfg_home" scrubbed "$bin" "$t" 2>"$tmp/err5"; then
  fail "expected failure on unrecognized config line"
fi
grep -q "unrecognized line" "$tmp/err5" || fail "missing loud unrecognized-line message"
printf 'warn=200000\nrestart=100000\n' > "$cfg_home/config/context-thresholds"
if FM_HOME="$cfg_home" scrubbed "$bin" "$t" 2>"$tmp/err6"; then
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

# 12. Auto-discovery reads the session's CLAUDE_CONFIG_DIR, not $HOME/.claude:
#     a transcript there wins even when the HOME copy is newer.
cfg_win_home="$tmp/cfg_win_home"
mkdir -p "$cfg_win_home"
munged="$(printf '%s' "$cfg_win_home" | tr -c 'a-zA-Z0-9' '-')"
cfg_store="$tmp/secondary_claude"
mkdir -p "$cfg_store/projects/$munged" "$tmp/claude_home/.claude/projects/$munged"
mk_line assistant false 2 400 600 > "$cfg_store/projects/$munged/session.jsonl"
mk_line assistant false 2 70000 80000 > "$tmp/claude_home/.claude/projects/$munged/session.jsonl"
touch -d '10 seconds ago' "$cfg_store/projects/$munged/session.jsonl"
touch "$tmp/claude_home/.claude/projects/$munged/session.jsonl"
out="$(CLAUDE_CONFIG_DIR="$cfg_store" HOME="$tmp/claude_home" FM_HOME="$cfg_win_home" scrubbed "$bin")"
case "$out" in
  *"context_tokens=1002 "*"transcript=$cfg_store/projects/$munged/session.jsonl"*) ;;
  *) fail "auto-discovery must read CLAUDE_CONFIG_DIR over \$HOME/.claude, got: $out" ;;
esac

# 13. A relative CLAUDE_CONFIG_DIR is refused rather than resolved against
#     this process's cwd.
if CLAUDE_CONFIG_DIR="relative/claude-store" HOME="$tmp/claude_home" FM_HOME="$cfg_win_home" scrubbed "$bin" 2>"$tmp/err_rel_cfg"; then
  fail "expected refusal for a relative CLAUDE_CONFIG_DIR"
fi
grep -q "relative path" "$tmp/err_rel_cfg" || fail "missing loud relative CLAUDE_CONFIG_DIR message"

# 14. A stale self-read reports band=unavailable, never a confident band, and
#     the staleness limit can be overridden.
stale_home="$tmp/stale_home"
mkdir -p "$stale_home"
munged="$(printf '%s' "$stale_home" | tr -c 'a-zA-Z0-9' '-')"
stale_store="$tmp/stale_claude"
mkdir -p "$stale_store/projects/$munged"
stale_t="$stale_store/projects/$munged/session.jsonl"
mk_line assistant false 2 400 600 > "$stale_t"
touch -d '2 hours ago' "$stale_t"
out="$(CLAUDE_CONFIG_DIR="$stale_store" HOME="$tmp/claude_home" FM_HOME="$stale_home" scrubbed "$bin")"
case "$out" in
  *"context_tokens=1002 "*" band=unavailable "*) ;;
  *) fail "expected band=unavailable for a stale auto-picked transcript, got: $out" ;;
esac
case "$out" in
  *" reason=stale-transcript"*) ;;
  *) fail "expected reason=stale-transcript for a stale auto-picked transcript, got: $out" ;;
esac
out="$(CLAUDE_CONFIG_DIR="$stale_store" HOME="$tmp/claude_home" FM_HOME="$stale_home" FM_CONTEXT_STALE_SECONDS=999999 scrubbed "$bin")"
case "$out" in
  *" band=ok "*) ;;
  *) fail "expected FM_CONTEXT_STALE_SECONDS to override the staleness limit, got: $out" ;;
esac

# 15. An explicit transcript argument is trusted as given, even when stale, and
#     carries no self-read pick field.
out="$(CLAUDE_CONFIG_DIR="$stale_store" HOME="$tmp/claude_home" FM_HOME="$stale_home" scrubbed "$bin" "$stale_t")"
case "$out" in
  *" band=ok "*) ;;
  *) fail "expected an explicit stale transcript to report its real band, got: $out" ;;
esac
case "$out" in
  *"reason="*) fail "explicit transcript must not carry a stale reason, got: $out" ;;
esac
case "$out" in
  *"pick="*) fail "an explicit transcript must not carry a pick field, got: $out" ;;
esac

# 16. A malformed staleness override is rejected loudly, never defaulted.
if CLAUDE_CONFIG_DIR="$stale_store" HOME="$tmp/claude_home" FM_HOME="$stale_home" FM_CONTEXT_STALE_SECONDS=abc scrubbed "$bin" 2>"$tmp/err_stale_cfg"; then
  fail "expected failure on malformed FM_CONTEXT_STALE_SECONDS"
fi
grep -q "FM_CONTEXT_STALE_SECONDS" "$tmp/err_stale_cfg" || fail "missing loud malformed staleness message"

# 16b. FM_CONTEXT_STALE_SECONDS=0 is the helper's documented guard-off value: a
#      reader of a session that is idle by definition reports its last real band
#      instead of band=unavailable.
out="$(CLAUDE_CONFIG_DIR="$stale_store" HOME="$tmp/claude_home" FM_HOME="$stale_home" FM_CONTEXT_STALE_SECONDS=0 scrubbed "$bin")"
case "$out" in
  *"context_tokens=1002 "*" band=ok "*) ;;
  *) fail "expected FM_CONTEXT_STALE_SECONDS=0 to turn the staleness guard off, got: $out" ;;
esac
case "$out" in
  *"reason="*) fail "a guard that is off must not carry a stale reason, got: $out" ;;
esac

# 17. A cross-session read of a crew launched on the ordinary account (no
#     CLAUDE_CONFIG_DIR) still finds that crew's transcript when this process
#     carries another store: the caller's store has no project directory for
#     that home, so the read falls back to $HOME/.claude instead of reporting no
#     evidence. The staleness guard stays on for the fallback too.
ordinary_home="$tmp/ordinary_home"
mkdir -p "$ordinary_home"
munged="$(printf '%s' "$ordinary_home" | tr -c 'a-zA-Z0-9' '-')"
caller_store="$tmp/caller_store"
mkdir -p "$caller_store/projects" "$tmp/claude_home/.claude/projects/$munged"
ordinary_t="$tmp/claude_home/.claude/projects/$munged/session.jsonl"
mk_line assistant false 10 0 259990 > "$ordinary_t"
out="$(CLAUDE_CONFIG_DIR="$caller_store" HOME="$tmp/claude_home" FM_HOME="$ordinary_home" scrubbed "$bin")"
case "$out" in
  *"band=restart "*"transcript=$ordinary_t"*) ;;
  *) fail "expected the default store to be read when the caller's store has no project directory, got: $out" ;;
esac
touch -d '2 hours ago' "$ordinary_t"
out="$(CLAUDE_CONFIG_DIR="$caller_store" HOME="$tmp/claude_home" FM_HOME="$ordinary_home" scrubbed "$bin")"
case "$out" in
  *" band=unavailable "*"transcript=$ordinary_t"*"reason=stale-transcript"*) ;;
  *) fail "expected the staleness guard on a fallback-resolved transcript, got: $out" ;;
esac

# 18. FM_CLAUDE_STORE names the TARGET session's store, the account= a pinned
#     spawn recorded: its absolute root wins over both this process's store and
#     $HOME/.claude, which each hold a directory for the same home.
pinned_home="$tmp/pinned_home"
mkdir -p "$pinned_home"
munged="$(printf '%s' "$pinned_home" | tr -c 'a-zA-Z0-9' '-')"
pinned_store="$tmp/pinned_store"
mkdir -p "$pinned_store/projects/$munged" "$caller_store/projects/$munged" "$tmp/claude_home/.claude/projects/$munged"
mk_line assistant false 10 0 992 > "$pinned_store/projects/$munged/session.jsonl"
mk_line assistant false 10 0 259990 > "$caller_store/projects/$munged/session.jsonl"
mk_line assistant false 10 0 259990 > "$tmp/claude_home/.claude/projects/$munged/session.jsonl"
out="$(FM_CLAUDE_STORE="$pinned_store" CLAUDE_CONFIG_DIR="$caller_store" HOME="$tmp/claude_home" FM_HOME="$pinned_home" scrubbed "$bin")"
case "$out" in
  *"band=ok "*"transcript=$pinned_store/projects/$munged/session.jsonl"*) ;;
  *) fail "expected FM_CLAUDE_STORE to select the target session's store, got: $out" ;;
esac
case "$out" in
  *"pick="*) fail "a targeted read must not carry a pick field, got: $out" ;;
esac

# 19. FM_CLAUDE_STORE=ordinary is the vendor default login, $HOME/.claude, even
#     while this process carries another store.
out="$(FM_CLAUDE_STORE=ordinary CLAUDE_CONFIG_DIR="$pinned_store" HOME="$tmp/claude_home" FM_HOME="$pinned_home" scrubbed "$bin")"
case "$out" in
  *"band=restart "*"transcript=$tmp/claude_home/.claude/projects/$munged/session.jsonl"*) ;;
  *) fail "expected FM_CLAUDE_STORE=ordinary to read \$HOME/.claude, got: $out" ;;
esac

# 20. A relative or unrecognized FM_CLAUDE_STORE is refused loudly, never
#     resolved against this process's cwd.
if FM_CLAUDE_STORE="relative/store" HOME="$tmp/claude_home" FM_HOME="$pinned_home" scrubbed "$bin" 2>"$tmp/err_store_rel"; then
  fail "expected refusal for a relative FM_CLAUDE_STORE"
fi
grep -q "FM_CLAUDE_STORE" "$tmp/err_store_rel" || fail "missing loud relative FM_CLAUDE_STORE message"

# 21. FM_CLAUDE_STORE=ordinary without HOME cannot name the default login.
if FM_CLAUDE_STORE=ordinary FM_HOME="$pinned_home" env -u HOME -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u HERDR_PANE_ID "$bin" 2>"$tmp/err_store_home"; then
  fail "expected refusal for FM_CLAUDE_STORE=ordinary without HOME"
fi
grep -q "FM_CLAUDE_STORE" "$tmp/err_store_home" || fail "missing loud FM_CLAUDE_STORE=ordinary message"

# 22. A targeted read reports the target's last real band however old its
#     transcript is: FM_CLAUDE_STORE=auto falls back to $HOME/.claude for a home
#     whose store has no project directory there, and skips the guard section 17
#     shows suppressing that same stale transcript on a self-read.
out="$(FM_CLAUDE_STORE=auto CLAUDE_CONFIG_DIR="$caller_store" HOME="$tmp/claude_home" FM_HOME="$ordinary_home" scrubbed "$bin")"
case "$out" in
  *"band=restart "*"transcript=$ordinary_t"*) ;;
  *) fail "expected a targeted auto read to report the real band of a stale transcript, got: $out" ;;
esac
case "$out" in
  *"reason="*) fail "a targeted read must not carry a stale reason, got: $out" ;;
esac

# 23. A named target store does the same for a transcript old enough to be
#     unavailable to a self-read.
touch -d '2 hours ago' "$pinned_store/projects/$munged/session.jsonl"
out="$(FM_CLAUDE_STORE="$pinned_store" CLAUDE_CONFIG_DIR="$caller_store" HOME="$tmp/claude_home" FM_HOME="$pinned_home" scrubbed "$bin")"
case "$out" in
  *"band=ok "*"transcript=$pinned_store/projects/$munged/session.jsonl"*) ;;
  *) fail "expected a named target store to report the real band of a stale transcript, got: $out" ;;
esac
case "$out" in
  *"reason="*) fail "a targeted read must not carry a stale reason, got: $out" ;;
esac

# 24. A self-read binds to the calling session's own transcript, not the newest:
#     another live session in the same home appends to a fresher file, and that
#     file must not become this session's reading.
bind_home="$tmp/bind_home"
mkdir -p "$bind_home"
munged="$(printf '%s' "$bind_home" | tr -c 'a-zA-Z0-9' '-')"
bind_proj="$tmp/bind_store/projects/$munged"
mkdir -p "$bind_proj"
mk_line assistant false 2 400 600 > "$bind_proj/mine.jsonl"
mk_line assistant false 2 150000 36990 > "$bind_proj/other.jsonl"
touch -d '2 minutes ago' "$bind_proj/mine.jsonl"
touch -d '1 minute ago' "$bind_proj/other.jsonl"
out="$(CLAUDE_CONFIG_DIR="$tmp/bind_store" HOME="$tmp/claude_home" FM_HOME="$bind_home" scrubbed CLAUDE_CODE_SESSION_ID=mine "$bin")"
case "$out" in
  *"context_tokens=1002 "*"transcript=$bind_proj/mine.jsonl"*" pick=session"*) ;;
  *) fail "a self-read must bind to its own session's transcript, got: $out" ;;
esac

# 25. An id with no transcript of its own falls back to the newest pick and says
#     so, rather than failing or presenting that file as the session's reading.
out="$(CLAUDE_CONFIG_DIR="$tmp/bind_store" HOME="$tmp/claude_home" FM_HOME="$bind_home" scrubbed CLAUDE_CODE_SESSION_ID=never-wrote "$bin")"
case "$out" in
  *"transcript=$bind_proj/other.jsonl"*" pick=newest"*) ;;
  *) fail "expected the newest-mtime fallback with pick=newest, got: $out" ;;
esac

# 26. The staleness guard still applies to a session-bound self-read: a stale
#     own transcript is unavailable, not a confident band.
bind_stale_store="$tmp/bind_stale_store"
mkdir -p "$bind_stale_store/projects/$munged"
bind_stale_t="$bind_stale_store/projects/$munged/mine.jsonl"
mk_line assistant false 2 400 600 > "$bind_stale_t"
touch -d '2 hours ago' "$bind_stale_t"
out="$(CLAUDE_CONFIG_DIR="$bind_stale_store" HOME="$tmp/claude_home" FM_HOME="$bind_home" scrubbed CLAUDE_CODE_SESSION_ID=mine "$bin")"
case "$out" in
  *" band=unavailable "*"transcript=$bind_stale_t"*" pick=session"*" reason=stale-transcript"*) ;;
  *) fail "expected a stale session-bound self-read to be unavailable, got: $out" ;;
esac

# 27. An id shaped like a path is ignored, so it can never name a file outside
#     the project directory; the newest-mtime fallback still reports a reading.
out="$(CLAUDE_CONFIG_DIR="$tmp/bind_store" HOME="$tmp/claude_home" FM_HOME="$bind_home" scrubbed CLAUDE_CODE_SESSION_ID='../other' "$bin")"
case "$out" in
  *"transcript=$bind_proj/other.jsonl"*" pick=newest"*) ;;
  *) fail "expected a path-shaped session id to be ignored, got: $out" ;;
esac

echo "PASS fm-context-usage.test.sh"
