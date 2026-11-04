#!/usr/bin/env bash
# fm-free-model-probe.sh - probe whether a free OpenCode model is available or capped.
#
# Usage: fm-free-model-probe.sh <opencode-model-id> [timeout-secs]
#
# Runs `opencode run -m <model-id> "Reply with exactly: OK"` from a temporary
# directory with an optional timeout (default 60 seconds), then checks OpenCode's
# log directory for a "Free usage limit reached" entry written for that modelID
# since the probe started.
#
# Prints exactly one line to stdout:
#   ok              the reply contained "OK" (exit 0)
#   capped <retry>  a log entry for <model-id> since the probe start contained
#                   "Free usage limit reached" (<retry> is the retry time from
#                   the log message, or "unknown retry" if not parseable) (exit 3)
#   unknown <why>   the probe timed out or produced other output (exit 1)
#
# OpenCode logs live in ~/.local/share/opencode/log/; the newest file in that
# directory is the current log.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MODEL_ID=${1:?usage: fm-free-model-probe.sh <opencode-model-id> [timeout-secs]}
TIMEOUT_SEC=${2:-60}

OPENCODE_LOG_DIR="${OPENCODE_LOG_DIR:-$HOME/.local/share/opencode/log}"

# Determine the cutoff epoch: log entries written after this time are "since probe start".
PROBE_START_EPOCH=$(date +%s)

# Create a temporary work dir for the probe command.
PROBE_TMPDIR=$(mktemp -d)
trap 'rm -rf "$PROBE_TMPDIR"' EXIT

# Run the probe with a timeout. Capture stdout, stderr, and exit code.
PROBE_OUTPUT_FILE="$PROBE_TMPDIR/output.txt"
PROBE_EXIT_FILE="$PROBE_TMPDIR/exit.txt"
timeout "$TIMEOUT_SEC" bash -c '
  opencode run -m "$1" "Reply with exactly: OK" >"$2" 2>&1
  echo $? >"$3"
' _ "$MODEL_ID" "$PROBE_OUTPUT_FILE" "$PROBE_EXIT_FILE" &
PROBE_PID=$!

# Wait for the timeout or the probe to finish.
wait "$PROBE_PID" 2>/dev/null || true
PROBE_EXIT_CODE=124
if [ -f "$PROBE_EXIT_FILE" ]; then
  PROBE_EXIT_CODE=$(cat "$PROBE_EXIT_FILE" 2>/dev/null || echo 124)
fi

OUTPUT=$(cat "$PROBE_OUTPUT_FILE" 2>/dev/null || true)

# Check if the reply contains "OK".
if echo "$OUTPUT" | grep -q "OK"; then
  echo "ok"
  exit 0
fi

# Check OpenCode logs for "Free usage limit reached" for this modelID.
# The newest log file is the current one.
CAPED_REASON=""
if [ -d "$OPENCODE_LOG_DIR" ]; then
  # Find the newest log file.
  CURRENT_LOG=$(ls -t "$OPENCODE_LOG_DIR"/* 2>/dev/null | head -1)
  if [ -n "$CURRENT_LOG" ] && [ -f "$CURRENT_LOG" ]; then
    # Look for log entries for this modelID that contain "Free usage limit reached".
    # Log format is JSON: ... "modelID":"glm-5.3-flash-free" ... "error":"AI_APICallError: Free usage limit reached. ..."
    LOG_MATCH=$(grep "\"modelID\":\"${MODEL_ID}\"" "$CURRENT_LOG" 2>/dev/null | grep "Free usage limit reached" | tail -1)
    if [ -n "$LOG_MATCH" ]; then
      # Extract the retry time if present (format: "retry after Xs" or similar).
      RETRY_TIME=$(echo "$LOG_MATCH" | grep -oP 'retry after \K[0-9]+' || true)
      if [ -n "$RETRY_TIME" ]; then
        CAPED_REASON="retry after ${RETRY_TIME}s"
      else
        CAPED_REASON="unknown retry"
      fi
      echo "capped $CAPED_REASON"
      exit 3
    fi
  fi
fi

# Check if we timed out.
if [ "${PROBE_EXIT_CODE:-124}" -ge 124 ]; then
  echo "unknown probe timed out after ${TIMEOUT_SEC}s"
  exit 1
fi

# Other failure.
echo "unknown probe exit code ${PROBE_EXIT_CODE:-unknown}"
exit 1
