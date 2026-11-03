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
# Output is one data-only line; callers act on the reported band rather than
# re-deriving thresholds:
#   context_tokens=<N> window=<W> percent=<P> warn_tokens=<W1> \
#     restart_tokens=<W2> band=<ok|warn|restart> transcript=<path> age_seconds=<S>
# The window defaults to 1000000 and can be overridden with FM_CONTEXT_WINDOW
# when a harness or model change alters the real window.
#
# Bands implement the captain's session-context policy (directive 2026-08-26):
#   ok      - below the warning threshold; keep working.
#   warn    - at or past the warning threshold (default 150000); surface the
#             level in the next natural report.
#   restart - at or past the restart threshold (default 250000); the session
#             must not keep grinding: checkpoint durable state (/stow for a
#             firstmate home), restart with a carryover handoff
#             (bin/fm-control.sh <id> relaunch --note for a crewmate, or a
#             fresh session for a primary), and wake/advise the main session.
#             Never send /clear through the steer channel - it is mechanically
#             broken.
# Thresholds come from config/context-thresholds under the same home used for
# transcript discovery: optional `warn=<N>` and `restart=<N>` lines, one per
# line, each a positive base-10 integer, warn <= restart. A malformed file is
# rejected loudly rather than silently replaced by defaults. The file is
# inherited by secondmate homes via FM_INHERITABLE_CONFIG
# (bin/fm-config-inherit-lib.sh), so the primary's thresholds propagate.
# For another session's usage (a crewmate or secondmate), run with FM_HOME set
# to that session's working directory (task worktree or secondmate home).
#
# Subagent (sidechain) turns are excluded so a spawned helper's smaller
# context never masquerades as the primary session's usage.
#
# Fails with a clear message on exit 1 when no transcript or usage record
# exists - for example under a non-claude primary harness - rather than
# guessing.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

home_path="${FM_HOME:-$PWD}"

# Threshold resolution: defaults, then a strict optional config/context-thresholds.
warn_tokens=150000
restart_tokens=250000
thresholds_file="$home_path/config/context-thresholds"
if [ -e "$thresholds_file" ]; then
  if [ ! -f "$thresholds_file" ]; then
    echo "fm-context-usage: $thresholds_file is not a regular file" >&2
    exit 1
  fi
  while IFS= read -r tline || [ -n "$tline" ]; do
    case "$tline" in
      '') continue ;;
      warn=*)
        val="${tline#warn=}"
        case "$val" in ''|*[!0-9]*) echo "fm-context-usage: malformed warn value in $thresholds_file: $tline" >&2; exit 1 ;; esac
        warn_tokens="$val" ;;
      restart=*)
        val="${tline#restart=}"
        case "$val" in ''|*[!0-9]*) echo "fm-context-usage: malformed restart value in $thresholds_file: $tline" >&2; exit 1 ;; esac
        restart_tokens="$val" ;;
      *)
        echo "fm-context-usage: unrecognized line in $thresholds_file: $tline" >&2
        exit 1 ;;
    esac
  done < "$thresholds_file"
  if [ "$warn_tokens" -le 0 ] || [ "$restart_tokens" -le 0 ] || [ "$warn_tokens" -gt "$restart_tokens" ]; then
    echo "fm-context-usage: thresholds must be positive with warn <= restart in $thresholds_file (warn=$warn_tokens restart=$restart_tokens)" >&2
    exit 1
  fi
fi

transcript="${1:-}"
if [ -z "$transcript" ]; then
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

python3 - "$transcript" "$window" "$warn_tokens" "$restart_tokens" <<'PY'
import json, os, sys, time

path, window = sys.argv[1], int(sys.argv[2])
warn, restart = int(sys.argv[3]), int(sys.argv[4])
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
band = "restart" if total >= restart else "warn" if total >= warn else "ok"
print(
    "context_tokens=%d window=%d percent=%.1f warn_tokens=%d restart_tokens=%d"
    " band=%s transcript=%s age_seconds=%d"
    % (
        total,
        window,
        100.0 * total / window if window else 0.0,
        warn,
        restart,
        band,
        path,
        age,
    )
)
PY
