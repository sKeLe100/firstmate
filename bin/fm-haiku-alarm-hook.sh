#!/usr/bin/env bash
# bin/fm-haiku-alarm-hook.sh - Claude Code hook for a haiku-builder subagent:
# a warning at 80k context and a stop at 95k, except checkpoint writes (slice 1
# of the Haiku swarm design, section 5 item 2; design in
# data/haiku-swarm-coordinator-design/report.md section 2b).
#
# Wiring: the example agent (docs/examples/claude-agents/haiku-builder.md) runs
# this one script from both PostToolUse and PreToolUse in its own frontmatter, so
# it fires only inside that subagent and never touches the parent session. The
# hook reads the event from the input's hook_event_name.
#
# Input: the hook's JSON on stdin. A subagent's hook input carries agent_id and
# session_id; no agent_id means the call is not from a subagent, and the hook
# does nothing.
#
# Context is read by bin/fm-subagent-context.sh from the subagent's transcript.
# That transcript lags by up to one turn, so for PostToolUse the size of the
# tool result just returned is added as an estimate (characters / 3). PreToolUse
# uses the transcript figure alone, because the hook input carries no result.
#
# Decisions (fixed thresholds: warn at 80000 and deny at 95000):
#   PostToolUse, warn <= context < deny   prints additionalContext with the 80k
#                                          text (finish only the current step,
#                                          open no new files, quiet tests, then
#                                          reply DONE/NEXT/FILES-TOUCHED).
#   PreToolUse,  context >= deny          prints permissionDecision deny with the
#                                          95k text, EXCEPT a Write or Edit whose
#                                          file_path equals FM_CHECKPOINT_PATH,
#                                          which is allowed so the delegate can
#                                          write its checkpoint.
#   Anything else                          prints nothing (default allow).
#
# Output is one JSON object on stdout, or nothing. Exit codes:
#   0  decision printed, or nothing to say. A reader exit 3 (the subagent file
#      exists but has no assistant usage row yet) is silent; a reader exit 1
#      (the subagent transcript is missing) writes one stderr line naming the
#      path and still exits 0, so it never blocks the tool call.
#   1  malformed hook input, or the subagent context reader failed unexpectedly.
#      Stderr names the cause; this is loud, not silently allowed.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 0
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

py_hook="$(cat <<'PY'
import json, os, subprocess, sys

here = sys.argv[1]
warn, deny = 80000, 95000

try:
    data = json.loads(sys.stdin.read() or "{}")
except ValueError as exc:
    sys.stderr.write("fm-haiku-alarm-hook: malformed hook input JSON: %s\n" % exc)
    sys.exit(1)
if not isinstance(data, dict):
    sys.stderr.write("fm-haiku-alarm-hook: hook input is not a JSON object\n")
    sys.exit(1)

event = data.get("hook_event_name")
agent_id = data.get("agent_id")
if not agent_id or event not in ("PostToolUse", "PreToolUse"):
    sys.exit(0)

session_id = data.get("session_id")
transcript = data.get("transcript_path")
if not session_id or not transcript:
    sys.stderr.write("fm-haiku-alarm-hook: subagent hook input lacks session_id or transcript_path\n")
    sys.exit(1)

reader = subprocess.run(
    [os.path.join(here, "fm-subagent-context.sh"), transcript, session_id, agent_id],
    capture_output=True,
    text=True,
)
if reader.returncode == 3:
    # No completed subagent turn on disk yet: the context is far below the warn
    # line, so there is nothing to say.
    sys.exit(0)
if reader.returncode == 1:
    detail = (reader.stderr or "").strip() or "context reader failed"
    sys.stderr.write("fm-haiku-alarm-hook: %s\n" % detail)
    sys.exit(0)
if reader.returncode != 0:
    sys.stderr.write("fm-haiku-alarm-hook: context reader failed: %s" % reader.stderr)
    sys.exit(1)
marker = "context_tokens="
context = int(reader.stdout.split(marker, 1)[1].split()[0])

lag = 0
if event == "PostToolUse":
    response = data.get("tool_response")
    if response is not None:
        text = response if isinstance(response, str) else json.dumps(response, ensure_ascii=False)
        lag = len(text) // 3
total = context + lag

WARN_TEXT = (
    "Context ~%dk of a 100k price line. Finish only the current AC step. "
    "Open no new files. Run tests quietly (tail only). "
    "Next reply: report DONE/NEXT/FILES-TOUCHED."
) % (total // 1000)
DENY_TEXT = (
    "95k: stop now, reply with checkpoint (done, next step, files touched, AC status). "
    "Only a Write or Edit to your checkpoint path is still allowed."
)

if event == "PostToolUse":
    if warn <= total < deny:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": WARN_TEXT,
        }}))
    sys.exit(0)

# PreToolUse: the hard stop.
if total < deny:
    sys.exit(0)

tool_name = data.get("tool_name") or ""
tool_input = data.get("tool_input") or {}
checkpoint = os.environ.get("FM_CHECKPOINT_PATH", "")
if (
    checkpoint
    and tool_name in ("Write", "Edit")
    and isinstance(tool_input, dict)
    and tool_input.get("file_path")
    and os.path.abspath(tool_input["file_path"]) == os.path.abspath(checkpoint)
):
    sys.exit(0)

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": DENY_TEXT,
}}))
PY
)"

printf '%s' "$(cat)" | python3 -c "$py_hook" "$here"
