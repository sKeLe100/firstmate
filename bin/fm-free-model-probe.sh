#!/usr/bin/env bash
# fm-free-model-probe.sh - probe whether a free OpenCode model is available or capped.
#
# Usage: fm-free-model-probe.sh <opencode-model-id> [timeout-secs]
#
# <opencode-model-id> may be bare or provider-qualified as <provider>/<model-id>.
#
# Runs `opencode run -m <model-id> "Reply with exactly: OK"` from a temporary
# directory with an optional timeout (default 60 seconds), then checks OpenCode's
# logfmt log for a "Free usage limit reached" entry written for that modelID
# since the probe started.
#
# Prints exactly one line to stdout for a probe result:
#   ok              the reply was exactly "OK" (exit 0)
#   capped <retry>  a log entry for <model-id> since the probe start contained
#                   "Free usage limit reached" (<retry> is the retry time from
#                   the log message, or "unknown retry" if not parseable) (exit 3)
#   unknown <why>   the probe timed out or produced other output (exit 1)
# A usage error prints no stdout line and exits 2.
#
# OpenCode writes logfmt lines to ~/.local/share/opencode/log/opencode.log
# (override with FM_OPENCODE_LOG).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: fm-free-model-probe.sh <opencode-model-id> [timeout-secs]

<opencode-model-id> may be bare or provider-qualified as <provider>/<model-id>.

Runs `opencode run -m <model-id> "Reply with exactly: OK"` from a temporary
directory with an optional timeout (default 60 seconds), then checks OpenCode's
log file for a "Free usage limit reached" entry written for that modelID since
the probe started.

Prints exactly one line to stdout for a probe result:
  ok              the reply was exactly "OK" (exit 0)
  capped <retry>  a log entry for <model-id> since the probe start contained
                  "Free usage limit reached" (<retry> is the retry time from
                  the log message, or "unknown retry" if not parseable) (exit 3)
  unknown <why>   the probe timed out or produced other output (exit 1)

A usage error prints no stdout line and exits 2.

OpenCode writes logfmt lines to ~/.local/share/opencode/log/opencode.log
(override with FM_OPENCODE_LOG).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    -*) printf 'fm-free-model-probe: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  usage >&2
  exit 2
fi

MODEL_ID=$1
TIMEOUT_SEC=${2:-60}
case "$TIMEOUT_SEC" in
  '' | 0* | *[!0-9]*)
    printf 'fm-free-model-probe: timeout must be a positive integer\n' >&2
    usage >&2
    exit 2
    ;;
esac

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

OPENCODE_LOG="${FM_OPENCODE_LOG:-${HOME:-}/.local/share/opencode/log/opencode.log}"

PROBE_START_EPOCH=$(date +%s)

PROBE_TMPDIR=$(mktemp -d) || {
  printf 'fm-free-model-probe: cannot create a temp dir\n' >&2
  exit 1
}
trap 'rm -rf "$PROBE_TMPDIR"' EXIT

PROBE_STDOUT_FILE="$PROBE_TMPDIR/stdout.txt"
PROBE_STDERR_FILE="$PROBE_TMPDIR/stderr.txt"
(
  cd "$PROBE_TMPDIR" || exit 1
  fm_run_timed "$TIMEOUT_SEC" opencode run -m "$MODEL_ID" "Reply with exactly: OK"
) >"$PROBE_STDOUT_FILE" 2>"$PROBE_STDERR_FILE"
PROBE_EXIT_CODE=$?

OUTPUT=$(cat "$PROBE_STDOUT_FILE" 2>/dev/null || true)

if [ "$OUTPUT" = "OK" ]; then
  echo "ok"
  exit 0
fi

log_timestamp_epoch() {  # <log-line>
  local ts
  ts=$(printf '%s\n' "$1" | sed -n 's/^timestamp=\([^ ]*\).*/\1/p')
  [ -n "$ts" ] || return 1
  case "$ts" in
    *.*Z) ts="${ts%%.*}Z" ;;
  esac
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null \
    || date -u -d "$ts" +%s 2>/dev/null
}

CAPED_REASON=""
case "$MODEL_ID" in
  */*)
    MODEL_PROVIDER=${MODEL_ID%%/*}
    MODEL_BARE=${MODEL_ID#*/}
    ;;
  *)
    MODEL_PROVIDER=
    MODEL_BARE=$MODEL_ID
    ;;
esac
if [ -r "$OPENCODE_LOG" ]; then
  LOG_MATCH=$(awk -v full="$MODEL_ID" -v provider="$MODEL_PROVIDER" -v bare="$MODEL_BARE" '
    {
      if (!index($0, "Free usage limit reached")) next
      model_match = 0
      provider_match = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "modelID=" full) { print; next }
        if ($i == "modelID=" bare) model_match = 1
        if (provider != "" && $i == "providerID=" provider) provider_match = 1
      }
      if (provider != "" && model_match && provider_match) print
    }
  ' "$OPENCODE_LOG" 2>/dev/null | tail -n 1)
  if [ -n "$LOG_MATCH" ]; then
    LOG_EPOCH=$(log_timestamp_epoch "$LOG_MATCH") || LOG_EPOCH=
    if [ -n "$LOG_EPOCH" ] && [ "$LOG_EPOCH" -ge "$PROBE_START_EPOCH" ]; then
      RETRY_TIME=$(printf '%s\n' "$LOG_MATCH" | grep -oE 'retry after [0-9]+' | head -n 1 | grep -oE '[0-9]+' || true)
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

cat "$PROBE_STDERR_FILE" >&2 2>/dev/null || true

if fm_timed_out "$PROBE_EXIT_CODE"; then
  echo "unknown probe timed out after ${TIMEOUT_SEC}s"
  exit 1
fi

if [ "$PROBE_EXIT_CODE" -eq 0 ]; then
  echo "unknown probe output"
  exit 1
fi

echo "unknown probe exit code ${PROBE_EXIT_CODE}"
exit 1
