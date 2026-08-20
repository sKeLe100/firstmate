#!/usr/bin/env bash
# bin/fm-context-usage.sh - report a Claude session's real context usage from
# the harness's own durable transcript records.
#
# Why: the agent cannot run the terminal-side /context command itself, and the
# padded-countdown token reminder can stick at 0 for a whole session, so any
# captain-facing context number must come from a durable source instead.
# Every Claude Code transcript line for an assistant turn carries a usage
# object whose input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens sum is the context size actually sent for that turn,
# which is the same total the /context command displays.
#
# Usage: fm-context-usage.sh [transcript.jsonl]
#   With no argument, picks the most recently modified *.jsonl transcript in
#   the Claude project directory for this home (~/.claude/projects/<home path
#   with every non-alphanumeric character replaced by ->, home = FM_HOME or
#   the current directory). The active session appends to its transcript
#   continuously, so the newest file is the current session whenever one is
#   live.
#
# Output is one data-only line; callers apply their own thresholds:
#   context_tokens=<N> window=<W> percent=<P> transcript=<path> age_seconds=<S>
# The window defaults to 1000000 and can be overridden with FM_CONTEXT_WINDOW
# when a harness or model change alters the real window.
#
# Subagent (sidechain) turns are excluded so a spawned helper's smaller
# context never masquerades as the primary session's usage.
#
# Fails with a clear message on exit 1 when no transcript or usage record
# exists - for example under a non-claude primary harness - rather than
# guessing.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

transcript="${1:-}"
if [ -z "$transcript" ]; then
  home_path="${FM_HOME:-$PWD}"
  munged="$(printf '%s' "$home_path" | tr -c 'a-zA-Z0-9' '-')"
  proj_dir="$HOME/.claude/projects/$munged"
  if [ ! -d "$proj_dir" ]; then
    echo "fm-context-usage: no Claude transcript directory at $proj_dir (non-claude harness, or no session yet)" >&2
    exit 1
  fi
  transcript="$(find "$proj_dir" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  if [ -z "$transcript" ]; then
    echo "fm-context-usage: no *.jsonl transcript found under $proj_dir" >&2
    exit 1
  fi
fi

if [ ! -f "$transcript" ]; then
  echo "fm-context-usage: transcript not found: $transcript" >&2
  exit 1
fi

window="${FM_CONTEXT_WINDOW:-1000000}"

python3 - "$transcript" "$window" <<'PY'
import json, os, sys, time

path, window = sys.argv[1], int(sys.argv[2])
last = None
with open(path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line or '"usage"' not in line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("type") != "assistant" or entry.get("isSidechain"):
            continue
        usage = (entry.get("message") or {}).get("usage")
        if isinstance(usage, dict):
            last = usage

if last is None:
    sys.stderr.write("fm-context-usage: no assistant usage record in %s\n" % path)
    sys.exit(1)

total = sum(
    int(last.get(k) or 0)
    for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
)
age = max(0, int(time.time() - os.path.getmtime(path)))
print(
    "context_tokens=%d window=%d percent=%.1f transcript=%s age_seconds=%d"
    % (total, window, 100.0 * total / window if window else 0.0, path, age)
)
PY
