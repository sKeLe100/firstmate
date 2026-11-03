#!/usr/bin/env bash
# bin/fm-subagent-context.sh - report a subagent's current context size from
# its own durable transcript file (slice 1 of the Haiku swarm design, section 5
# item 1; design in data/haiku-swarm-coordinator-design/report.md section 2b).
#
# Why: the Haiku context-alarm hook (bin/fm-haiku-alarm-hook.sh) and any future
# per-subagent reader need the size of one subagent's context, and the main
# session's transcript does not carry it. Claude Code writes each subagent's
# turns to <project-dir>/<session_id>/subagents/agent-<agent_id>.jsonl, and every
# assistant row there carries a usage object.
#
# Reused rather than reinvented: the context size is the same sum
# bin/fm-context-usage.sh reports for a main session - input_tokens +
# cache_creation_input_tokens + cache_read_input_tokens of the LAST assistant row
# carrying usage. That script cannot read a subagent file as-is: its usage parse
# lives inline and deliberately skips sidechain rows (every subagent row is one),
# and it is out of scope to change here. So this script keeps the same sum and
# the same last-usage rule without the sidechain filter.
#
# Usage: fm-subagent-context.sh <transcript_path> <session_id> <agent_id>
#   transcript_path is the parent session's transcript (the hook input's
#   transcript_path). The subagent file is
#   <dirname of transcript_path>/<session_id>/subagents/agent-<agent_id>.jsonl.
#
# Output is one data-only line:
#   context_tokens=<N> agent=<id> model=<m>
# model is the model field of that same last assistant row, empty when absent.
#
# Exit codes:
#   0  printed the line above.
#   1  the subagent file is missing. One clear line goes to stderr.
#   2  bad arguments or a session_id/agent_id that is not a plain identifier
#      (refused so a crafted id cannot escape the subagents directory).
#   3  the subagent file exists but holds no assistant usage row yet (a
#      brand-new subagent before its first completed turn). One clear line goes
#      to stderr.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ "$#" -ne 3 ]; then
  echo "usage: fm-subagent-context.sh <transcript_path> <session_id> <agent_id>" >&2
  exit 2
fi

transcript="$1"
session_id="$2"
agent_id="$3"

for ident in "$session_id" "$agent_id"; do
  case "$ident" in
    ''|*[!A-Za-z0-9_-]*)
      echo "fm-subagent-context: session_id and agent_id must be plain identifiers: '$ident'" >&2
      exit 2 ;;
  esac
done

subagent_file="$(dirname "$transcript")/$session_id/subagents/agent-$agent_id.jsonl"
if [ ! -f "$subagent_file" ]; then
  echo "fm-subagent-context: no subagent transcript at $subagent_file" >&2
  exit 1
fi

python3 - "$subagent_file" "$agent_id" <<'PY'
import json, sys

path, agent_id = sys.argv[1], sys.argv[2]
last_usage = None
last_model = ""
with open(path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line or '"usage"' not in line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            # A partially written last line while the subagent is still running.
            continue
        if entry.get("type") != "assistant":
            continue
        message = entry.get("message") or {}
        usage = message.get("usage")
        if isinstance(usage, dict):
            last_usage = usage
            last_model = message.get("model") or ""

if last_usage is None:
    sys.stderr.write("fm-subagent-context: no assistant usage row in %s\n" % path)
    sys.exit(3)

total = sum(
    int(last_usage.get(key) or 0)
    for key in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
)
print("context_tokens=%d agent=%s model=%s" % (total, agent_id, last_model))
PY
