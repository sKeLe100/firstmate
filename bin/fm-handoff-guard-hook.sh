#!/usr/bin/env bash
# bin/fm-handoff-guard-hook.sh - Claude Code PreToolUse hook on the Agent tool:
# refuses a haiku-builder subagent launch whose estimated context would exceed
# the handoff budget (slice 1 of the Haiku swarm design, section 5 item 3; the
# estimate is design section 2c in data/haiku-swarm-coordinator-design/report.md).
#
# Wiring: install in the COORDINATOR session's settings with matcher Agent. It
# acts only when the launch is a haiku-builder (subagent_type "haiku-builder") or
# asks for model "haiku"; any other Agent call passes untouched and logs nothing.
#
# Estimate, in tokens (characters / 3, a conservative proxy for the tokenizer):
#   prompt            the whole Agent prompt
#   each FILES entry  the file's bytes / 3, or only the lines of a range given as
#                     path:START-END; a missing path counts 0 (a file to create)
#   start             FM_HANDOFF_START_TOKENS, default 36000, the measured fixed
#                     first-turn context of a native Haiku subagent
#   work              FM_HANDOFF_WORK_TOKENS, default 20000, the allowance for
#                     tool output, edits, and quiet test tails
#
# FILES block: a line starting with `FILES:`, followed by bullet lines
# `- <path>` or `- <path>:<START>-<END>` (any of -, *, +, or a numbered bullet,
# with blank lines allowed inside the block). The block ends at the first other
# non-blank line. A block with no entries counts as no block. Relative paths
# resolve against the hook input's cwd.
#
# Refusals (each a PreToolUse deny with a reason):
#   - no FILES block, or one with no entries;
#   - a FILES entry that is a directory (or ends with /);
#   - a FILES entry that is a glob (contains * ? or [);
#   - a FILES entry with an incomplete or invalid line range (START below 1, or
#     END before START);
#   - a FILES entry whose size or lines cannot be read;
#   - the estimate is over FM_HANDOFF_BUDGET (default 70000). The reason names the
#     three biggest parts and suggests the split.
# Anything else is allowed (no output).
#
# Logging: when FM_HANDOFF_LOG is set, every guarded decision appends exactly one
# JSON line {ts, decision, reason, estimate, budget, agent_type, parts}. A log
# failure warns on stderr and never suppresses the decision. The SubagentStop
# logger that records actual context is a later slice.
#
# Output is one JSON object on stdout for a deny, or nothing. Exit codes:
#   0  decision made (allow, deny, or not a guarded launch).
#   1  malformed hook input or an unusable threshold. Stderr names the cause.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 0
fi

budget="${FM_HANDOFF_BUDGET:-70000}"
start="${FM_HANDOFF_START_TOKENS:-36000}"
work="${FM_HANDOFF_WORK_TOKENS:-20000}"
for value in "$budget" "$start" "$work"; do
  case "$value" in
    ''|*[!0-9]*)
      echo "fm-handoff-guard-hook: budget and token settings must be non-negative integers (budget=$budget start=$start work=$work)" >&2
      exit 1 ;;
  esac
done
if [ "$budget" -le 0 ]; then
  echo "fm-handoff-guard-hook: FM_HANDOFF_BUDGET must be positive (got $budget)" >&2
  exit 1
fi

py_guard="$(cat <<'PY'
import json, math, os, re, sys, time

budget, start, work = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
log_path = os.environ.get("FM_HANDOFF_LOG", "")

try:
    data = json.loads(sys.stdin.read() or "{}")
except ValueError as exc:
    sys.stderr.write("fm-handoff-guard-hook: malformed hook input JSON: %s\n" % exc)
    sys.exit(1)
if not isinstance(data, dict):
    sys.stderr.write("fm-handoff-guard-hook: hook input is not a JSON object\n")
    sys.exit(1)

if data.get("tool_name") != "Agent":
    sys.exit(0)
tool_input = data.get("tool_input") or {}
if not isinstance(tool_input, dict):
    sys.stderr.write("fm-handoff-guard-hook: Agent tool_input is not an object\n")
    sys.exit(1)

subagent_type = tool_input.get("subagent_type")
model = tool_input.get("model")
if subagent_type != "haiku-builder" and model != "haiku":
    sys.exit(0)

prompt = tool_input.get("prompt") or ""
cwd = data.get("cwd") or os.getcwd()

def tokens_for_chars(count):
    return int(math.ceil(count / 3.0))

# Parse the FILES block.
entries = []
lines = prompt.splitlines()
files_line = None
for index, line in enumerate(lines):
    if re.match(r"^\s*FILES:", line):
        files_line = index
        break
if files_line is not None:
    for line in lines[files_line + 1:]:
        if not line.strip():
            continue
        match = re.match(r"^\s*(?:[-*+]|\d+[.)])\s+(\S.*?)\s*$", line)
        if not match:
            break
        entries.append(match.group(1))

violations = []
parts = [
    {"name": "prompt", "tokens": tokens_for_chars(len(prompt))},
    {"name": "start", "tokens": start},
    {"name": "work", "tokens": work},
]
if files_line is None or not entries:
    violations.append("no FILES: block; list the files the subagent will read or edit")
for entry in entries:
    path = entry
    first = last = None
    range_match = re.match(r"^(.+?):(\d*)-(\d*)$", entry)
    if range_match:
        path = range_match.group(1)
        if not range_match.group(2) or not range_match.group(3):
            violations.append("FILES entry has an incomplete line range: %s" % entry)
            parts.append({"name": "file:" + entry, "tokens": 0})
            continue
        first, last = int(range_match.group(2)), int(range_match.group(3))
        if first < 1 or last < first:
            violations.append("FILES entry has an invalid line range: %s" % entry)
            parts.append({"name": "file:" + entry, "tokens": 0})
            continue
    if any(ch in path for ch in "*?["):
        violations.append("FILES entry is a glob, not a file: %s" % path)
        parts.append({"name": "file:" + entry, "tokens": 0})
        continue
    if path.endswith("/") or os.path.isdir(os.path.join(cwd, path)):
        violations.append("FILES entry is a directory, not a file: %s" % path)
        parts.append({"name": "file:" + entry, "tokens": 0})
        continue
    full = path if os.path.isabs(path) else os.path.join(cwd, path)
    try:
        if not os.path.isfile(full):
            size = 0
        elif first is None:
            size = os.path.getsize(full)
        else:
            size = 0
            with open(full, "rb") as fh:
                for number, line in enumerate(fh, 1):
                    if number > last:
                        break
                    if number >= first:
                        size += len(line)
    except OSError as exc:
        violations.append("FILES entry cannot be read: %s (%s)" % (entry, exc))
        parts.append({"name": "file:" + entry, "tokens": 0})
        continue
    parts.append({"name": "file:" + entry, "tokens": tokens_for_chars(size)})

estimate = sum(part["tokens"] for part in parts)

if violations:
    decision, reason = "deny", "; ".join(violations)
elif estimate > budget:
    biggest = sorted(parts, key=lambda part: part["tokens"], reverse=True)[:3]
    named = ", ".join("%s ~%d" % (part["name"], part["tokens"]) for part in biggest)
    decision = "deny"
    reason = (
        "handoff estimate ~%d tokens is over the %d budget; biggest parts: %s. "
        "Split the chunk into smaller slices with fewer or smaller FILES entries."
    ) % (estimate, budget, named)
else:
    decision, reason = "allow", "within budget"

if decision == "deny":
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))

if log_path:
    try:
        os.makedirs(os.path.dirname(os.path.abspath(log_path)), exist_ok=True)
        row = {
            "ts": int(time.time()),
            "decision": decision,
            "reason": reason,
            "estimate": estimate,
            "budget": budget,
            "agent_type": subagent_type or model,
            "parts": parts,
        }
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row) + "\n")
    except OSError as exc:
        sys.stderr.write(
            "fm-handoff-guard-hook: could not append to FM_HANDOFF_LOG %s: %s\n"
            % (log_path, exc)
        )
PY
)"

printf '%s' "$(cat)" | python3 -c "$py_guard" "$budget" "$start" "$work"
