#!/usr/bin/env bash
# Antigravity CLI (agy) session-open adapter: the RUN tier transport for agy.
#
# Registered in tracked .agents/hooks.json for Antigravity's SessionStart step.
# It is a thin transport around bin/fm-sessionstart-run.sh, which remains the
# single owner of source routing, eligibility, and the digest itself.
#
# Antigravity injects a hook's `injectSteps[].systemMessage.systemMessage`
# straight into model context before the first turn. In a linked crewmate
# worktree without .fm-secondmate-home, fm-sessionstart-run.sh stands down
# silently and this wrapper prints empty JSON ({}).
#
# agy can fire SessionStart again mid-conversation (for example after a
# Stop-hook park), and re-injecting the full digest would repeat it in an
# already-open context. The payload's `conversationId` is forwarded to
# fm-sessionstart-run.sh, which stays silent for a repeated startup on a live
# session whose completed startup already served that same conversation, and
# re-emits for a new conversation under the same live process.
#
# Every path exits 0 and prints valid JSON.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Print the first string value for key $2 in the JSON payload $1. Parsed without
# jq so routing and dedupe still happen on a host that lacks it (output then
# falls back to {} below, which is the pre-existing compatibility contract).
json_string_field() {  # <payload> <key>
  printf '%s' "$1" | awk -v key="$2" '
    BEGIN { RS = "\"" }
    seen == 2 { print; exit }
    seen == 1 && $0 ~ /^[[:space:]]*:[[:space:]]*$/ { seen = 2; next }
    seen == 1 { seen = 0 }
    $0 == key { seen = 1 }
  '
}

SOURCE=
CONVERSATION_ID=
while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE=${2:-}
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*) SOURCE=${1#--source=}; shift ;;
    *) shift ;;
  esac
done

if [ ! -t 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  if [ -z "$SOURCE" ]; then
    SOURCE=$(json_string_field "$PAYLOAD" source)
  fi
  CONVERSATION_ID=$(json_string_field "$PAYLOAD" conversationId)
fi

RUN_ARGS=(--source "${SOURCE:-startup}")
[ -z "$CONVERSATION_ID" ] || RUN_ARGS+=(--conversation-id "$CONVERSATION_ID")

DIGEST=$("$SCRIPT_DIR/fm-sessionstart-run.sh" "${RUN_ARGS[@]}" </dev/null 2>/dev/null || true)
if [ -z "$DIGEST" ] || ! command -v jq >/dev/null 2>&1; then
  printf '{}\n'
  exit 0
fi

jq -cn --arg msg "$DIGEST" '{injectSteps:[{systemMessage:{systemMessage:$msg}}]}'
exit 0
