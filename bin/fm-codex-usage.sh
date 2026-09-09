#!/usr/bin/env bash
# bin/fm-codex-usage.sh - report a Codex session's token/quota state from its
# durable rollout file, as a data-only sibling of bin/fm-context-usage.sh.
#
# Why: `~/.codex/sessions` has no retention guarantee, and the 2026-09-05
# incident showed a single astra session burned 25% of the weekly window
# before anyone noticed. This script reads the rollout JSONL that Codex
# appends on every call and prints one line with context-band, weekly-quota,
# model-attribution, and turn-delta fields so firstmate's supervision and
# registered custom checks can catch a burn in progress rather than after
# the window is gone.
#
# Usage: fm-codex-usage.sh [rollout.jsonl] [--telemetry] [--task-id <id>]
#   With no argument, picks the most recently modified `rollout-*.jsonl` in
#   `~/.codex/sessions/` (scans year/month/day directories). The active
#   session appends to its rollout continuously, so the newest file is the
#   current session whenever one is live.
#
#   --telemetry  Append a `usage` event to `data/llm-usage/firstmate.jsonl`
#                (under FM_HOME or current directory) carrying the same
#                numbers the script prints, so the record survives rollout
#                rotation/deletion. Requires --task-id.
#   --task-id    Task identifier included in the telemetry event (required
#                when --telemetry is set).
#
# Output is one data-only line; callers act on the reported fields rather
# than re-deriving them:
#   context_tokens=<N> window=<W> percent=<P> band=<ok|warn|restart> \
#     session_total=<T> weekly_used_percent=<U> weekly_resets_at=<ISO> \
#     weekly_delta_points=<D> models_seen=<M> turns=<N> age_seconds=<S> \
#     rollout=<path>
#
# Bands follow the same ok/warn/restart shape as bin/fm-context-usage.sh:
#   ok      - context below the warn threshold; keep working.
#   warn    - at or past the warn threshold (default 150000 tokens);
#             surface the level in the next natural report.
#   restart - at or past the restart threshold (default 180000 tokens);
#             the session must checkpoint durable state, restart fresh
#             with carryover, and not continue grinding.
#
# Thresholds come from optional config/codex-context-thresholds under
# FM_HOME (honoring FM_CONFIG_OVERRIDE): at most one `warn=<N>` line and
# one `restart=<N>` line, each a positive base-10 integer, warn <= restart.
# A malformed file is rejected loudly rather than silently replaced by
# defaults. Absent file or key means the built-in defaults warn=150000
# and restart=180000 (the Codex context window is ~258k, so these are
# approximately 58% and 70% respectively, mirroring the Claude policy).
#
# Fails with a clear message on exit 1 when no rollout or usable record
# exists - for example under a harness that does not use Codex - rather
# than guessing.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,51p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

home="${FM_HOME:-$PWD}"
data_dir="${FM_DATA_OVERRIDE:-$home/data}"

telemetry=0
task_id=""
rollout=""

# Parse all arguments: flags and positional args in any order.
while [ $# -gt 0 ]; do
  case "$1" in
    --telemetry) telemetry=1; shift ;;
    --task-id) task_id="${2:-}"; shift 2 ;;
    --task-id=*) task_id="${1#--task-id=}"; shift ;;
    --*) echo "fm-codex-usage: unknown flag: $1" >&2; exit 1 ;;
    *) rollout="$1"; shift ;;
  esac
done

# Threshold resolution: defaults, then optional config/codex-context-thresholds.
warn_tokens=150000
restart_tokens=180000
thresholds_file="${FM_CONFIG_OVERRIDE:-$home/config}/codex-context-thresholds"
if [ -f "$thresholds_file" ]; then
  while IFS= read -r tline || [ -n "$tline" ]; do
    case "$tline" in
      ''|'#'*) continue ;;
      warn=*)
        val="${tline#warn=}"
        case "$val" in ''|*[!0-9]*) echo "fm-codex-usage: malformed warn value in $thresholds_file: $tline" >&2; exit 1 ;; esac
        warn_tokens="$val" ;;
      restart=*)
        val="${tline#restart=}"
        case "$val" in ''|*[!0-9]*) echo "fm-codex-usage: malformed restart value in $thresholds_file: $tline" >&2; exit 1 ;; esac
        restart_tokens="$val" ;;
      *) echo "fm-codex-usage: unrecognized line in $thresholds_file: $tline" >&2; exit 1 ;;
    esac
  done < "$thresholds_file"
  if [ "$warn_tokens" -le 0 ] || [ "$restart_tokens" -le 0 ] || [ "$warn_tokens" -gt "$restart_tokens" ]; then
    echo "fm-codex-usage: thresholds must be positive with warn <= restart in $thresholds_file (warn=$warn_tokens restart=$restart_tokens)" >&2
    exit 1
  fi
fi

# Auto-discovery: find the newest rollout-*.jsonl under ~/.codex/sessions/.
if [ -z "$rollout" ]; then
  codex_dir="${CODEX_HOME:-$HOME/.codex}/sessions"
  if [ ! -d "$codex_dir" ]; then
    echo "fm-codex-usage: no Codex sessions directory at $codex_dir (non-codex harness, or no session yet)" >&2
    exit 1
  fi
  # Find the most recent file across all year/month subdirs.
  rollout="$(find "$codex_dir" -maxdepth 10 -name 'rollout-*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  if [ -z "$rollout" ]; then
    echo "fm-codex-usage: no rollout-*.jsonl found under $codex_dir" >&2
    exit 1
  fi
fi

if [ ! -f "$rollout" ]; then
  echo "fm-codex-usage: rollout not found: $rollout" >&2
  exit 1
fi

# Run the Python parser.
python3 - "$rollout" "$warn_tokens" "$restart_tokens" "$telemetry" "$task_id" "$data_dir" <<'PY'
import json, os, sys, time
from datetime import datetime, timezone

path = sys.argv[1]
warn = int(sys.argv[2])
restart = int(sys.argv[3])
do_telemetry = int(sys.argv[4])
task_id = sys.argv[5]
data_dir = sys.argv[6]

# Walk the file and collect all token_count and turn_context records.
token_counts = []        # list of (ordinal, payload) for token_count events
turn_contexts = []       # list of payloads for turn_context events (for model tracking)
first_timestamp = None
last_timestamp = None

with open(path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue

        ts = entry.get("timestamp")
        if ts:
            if first_timestamp is None:
                first_timestamp = ts
            last_timestamp = ts

        payload = entry.get("payload", {})
        if not isinstance(payload, dict):
            continue

        # Collect token_count records.
        if payload.get("type") == "token_count":
            token_counts.append((entry.get("ordinal", 0), payload))

        # Collect turn_context records for model attribution.
        if entry.get("type") == "turn_context":
            turn_contexts.append(payload)

if not token_counts:
    sys.stderr.write("fm-codex-usage: no token_count records in %s\n" % path)
    sys.exit(1)

# Sort by ordinal to ensure chronological order.
token_counts.sort(key=lambda x: x[0])

# Extract the last token_count's data.
last_payload = token_counts[-1][1]
info = last_payload.get("info") or {}
last_usage = info.get("last_token_usage") or {}
total_usage = info.get("total_token_usage") or {}
context_window = info.get("model_context_window") or 0

context_tokens = last_usage.get("input_tokens") or 0
session_total = total_usage.get("total_tokens") or 0

# Weekly quota from the last rate_limits record; fall back to previous record
# when the last record's primary is null (e.g. burn-against-exhausted account).
rate_limits = last_payload.get("rate_limits") or {}
primary = rate_limits.get("primary") or {}
weekly_used = primary.get("used_percent")
weekly_resets_epoch = primary.get("resets_at")

# If the last record has null primary, try the previous token_count.
prev_primary = {}
prev_used = 0
if not primary and len(token_counts) >= 2:
    prev_payload = token_counts[-2][1]
    prev_primary = prev_payload.get("rate_limits", {}).get("primary") or {}
    prev_used = prev_primary.get("used_percent") or 0
    if prev_primary:
        primary = prev_primary
        weekly_used = primary.get("used_percent")
        weekly_resets_epoch = primary.get("resets_at")

# Convert resets_at epoch to ISO 8601.
weekly_resets_at = ""
if weekly_resets_epoch:
    try:
        dt = datetime.fromtimestamp(weekly_resets_epoch, tz=timezone.utc)
        weekly_resets_at = dt.isoformat()
    except (OSError, OverflowError, ValueError):
        weekly_resets_at = str(weekly_resets_epoch)

# Compute weekly delta: difference in used_percent between last and second-last
# token_count records. Null rate_limits counts as 0.
weekly_delta = 0
if len(token_counts) >= 2:
    prev_payload = token_counts[-2][1]
    prev_pl = prev_payload.get("rate_limits", {}).get("primary") or {}
    prev_used = prev_pl.get("used_percent") or 0
    last_used = primary.get("used_percent") if primary else prev_used
    weekly_delta = (last_used or 0) - prev_used
    # Round to 1 decimal to avoid floating-point noise.
    weekly_delta = round(weekly_delta, 1)

# Model attribution: unique models from turn_context.payload.model records.
models_seen = set()
for tc_payload in turn_contexts:
    m = tc_payload.get("model")
    if m:
        models_seen.add(m)

# Session age from the file's mtime vs the first/last record timestamp.
file_mtime = os.path.getmtime(path)
if last_timestamp:
    # Parse ISO timestamp to epoch for age calculation.
    try:
        # Handle both with and without timezone suffix.
        ts_str = last_timestamp.replace("Z", "+00:00")
        record_epoch = datetime.fromisoformat(ts_str).replace(tzinfo=timezone.utc).timestamp()
        age = max(0, int(file_mtime - record_epoch))
    except (ValueError, TypeError):
        age = max(0, int(time.time() - file_mtime))
else:
    age = max(0, int(time.time() - file_mtime))

# Band derivation: context_tokens vs model_context_window.
percent = 0.0
if context_window:
    percent = round(100.0 * context_tokens / context_window, 1)

band = "restart" if context_tokens >= restart else "warn" if context_tokens >= warn else "ok"

# Print the data-only output line.
print(
    "context_tokens=%d window=%d percent=%.1f band=%s session_total=%d "
    "weekly_used_percent=%.1f weekly_resets_at=%s weekly_delta_points=%.1f "
    "models_seen=%s turns=%d age_seconds=%d rollout=%s"
    % (
        context_tokens,
        context_window,
        percent,
        band,
        session_total,
        weekly_used if weekly_used is not None else 0.0,
        weekly_resets_at,
        weekly_delta,
        ",".join(sorted(models_seen)) if models_seen else "none",
        len(token_counts),
        age,
        path,
    )
)

# Telemetry emission: write a usage event to firstmate.jsonl.
if do_telemetry and task_id:
    usage_file = os.path.join(data_dir, "llm-usage", "firstmate.jsonl")
    os.makedirs(os.path.dirname(usage_file), exist_ok=True)
    event = {
        "schema_version": 1,
        "ts": datetime.now(tz=timezone.utc).isoformat(),
        "source": "firstmate",
        "event_type": "usage",
        "task_id": task_id,
        "harness": "codex",
        "rollout": path,
        "context_tokens": context_tokens,
        "session_total": session_total,
        "weekly_used_percent": weekly_used if weekly_used is not None else 0.0,
        "weekly_delta_points": weekly_delta,
        "models_seen": ",".join(sorted(models_seen)) if models_seen else "none",
    }
    with open(usage_file, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(event) + "\n")
PY
