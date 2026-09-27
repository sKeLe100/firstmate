#!/usr/bin/env bash
# fm-dispatch-quota-cap.sh - the effective concurrent Claude dispatch cap
# after the quota ladder, and whether the paced Codex sidecar may spawn.
#
# Why: the /autonomous pass's step 3 reads the base cap from
# config/dispatch-cap and reduces it by the quota ladder in
# docs/configuration.md ("Concurrent autonomous dispatch cap and quota
# ladder"), and step 9's refill offers the Codex sidecar only while Codex's
# weekly pace is not ahead (config/crew-dispatch.json's tier notes). Both
# were prose rules re-derived by hand at every pass; this script is their
# one executable owner so the ladder can be fixture-tested (report test
# seam "Quota fixture") and never drifts between restatements.
#
# Usage: fm-dispatch-quota-cap.sh [--quota-json <file>]
#   --quota-json <file>  read the `quota-axi --json` (schemaVersion 5)
#                        document from <file> instead of running quota-axi;
#                        the test seam and offline replay use this.
#
# Base cap: config/dispatch-cap (absent = 3; malformed = refused). Ladder,
# each row applied as a ceiling on the running cap, tightest wins:
#   five_hour.percentRemaining < 25                           -> cap 2
#   five_hour.percentRemaining <= 15                          -> cap 1
#   pace: for each of five_hour and seven_day whose pace.status is "ahead",
#     burnMultiple > 1.15 -> cap 2, burnMultiple > 1.5 -> cap 1.  The
#     five_hour pace is ignored during the window's first 30 minutes, when a
#     small early spend reads as a large multiple.
# The ladder only reacts to burn outrunning the time left, so spend that is
# on pace keeps the base cap right up to the reset: the goal is for Claude
# usage to ride out the full window, not to stop early.
# Codex: codex_spawn is "no" whenever the codex provider's weekly window
# reports pace.status "ahead"; "yes" otherwise.
#
# Output ("key: value" lines, stable order):
#   effective_cap: <n>
#   codex_spawn: yes|no
#   claude_pace: <burnMultiple the pace rows used, 0.00 when none applied>
#
# Exit codes: 0 on success; 2 when the base cap is malformed, quota-axi is
# missing or returns an unexpected schema, or the claude/codex windows the
# ladder needs are absent - unmeasurable quota is refused, never read as
# headroom.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

DEFAULT_BASE_CAP=3

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

QUOTA_JSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quota-json)
      QUOTA_JSON="${2:?--quota-json needs a value}"
      if [ ! -f "$QUOTA_JSON" ]; then
        echo "fm-dispatch-quota-cap: --quota-json file does not exist: $QUOTA_JSON" >&2
        exit 2
      fi
      shift 2
      ;;
    *)
      echo "fm-dispatch-quota-cap: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

base=$DEFAULT_BASE_CAP
cap_file="$CONFIG/dispatch-cap"
if [ -e "$cap_file" ]; then
  if ! raw=$(cat "$cap_file" 2>/dev/null); then
    echo "fm-dispatch-quota-cap: cannot read $cap_file" >&2
    exit 2
  fi
  case "$raw" in
    *[!0-9]* | '' | 0*)
      echo "fm-dispatch-quota-cap: $cap_file must hold one positive integer, got: $raw" >&2
      exit 2
      ;;
  esac
  base=$raw
fi

if [ -n "$QUOTA_JSON" ]; then
  doc=$(cat "$QUOTA_JSON")
else
  command -v quota-axi >/dev/null 2>&1 || {
    echo "fm-dispatch-quota-cap: quota-axi not found on PATH" >&2
    exit 2
  }
  doc=$(quota-axi --json 2>/dev/null) || {
    echo "fm-dispatch-quota-cap: quota-axi --json failed" >&2
    exit 2
  }
fi

FM_CAP_BASE="$base" FM_CAP_DOC="$doc" python3 <<'PY'
import json
import os
import sys
from datetime import datetime

base = int(os.environ["FM_CAP_BASE"])

def refuse(msg):
    print(f"fm-dispatch-quota-cap: {msg}", file=sys.stderr)
    sys.exit(2)

try:
    doc = json.loads(os.environ["FM_CAP_DOC"])
except ValueError as exc:
    refuse(f"quota document is not JSON: {exc}")

if doc.get("schemaVersion") != 5:
    refuse(f"expected quota-axi schemaVersion 5, got: {doc.get('schemaVersion')!r}")

providers = {p.get("provider"): p for p in doc.get("providers", []) if isinstance(p, dict)}

def window(provider, wid):
    p = providers.get(provider)
    if p is None:
        refuse(f"quota document has no {provider} provider")
    for w in p.get("windows", []):
        if isinstance(w, dict) and w.get("id") == wid:
            return w
    refuse(f"{provider} provider has no {wid} window")

def number(w, key):
    v = w.get(key)
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        refuse(f"{w.get('id')} window has no numeric {key}")
    return v

def parse_ts(s, what):
    if not isinstance(s, str):
        refuse(f"missing timestamp: {what}")
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        refuse(f"unparseable timestamp {what}: {s}")

five = window("claude", "five_hour")
week = window("claude", "seven_day")
codex_week = window("codex", "weekly")

five_pct = number(five, "percentRemaining")

def pace_burn(w):
    pace = w.get("pace") if isinstance(w.get("pace"), dict) else {}
    if pace.get("status") != "ahead":
        return 0
    burn = pace.get("burnMultiple")
    return burn if isinstance(burn, (int, float)) and not isinstance(burn, bool) else 0

generated = parse_ts(doc.get("generatedAt"), "generatedAt")
resets = parse_ts(five.get("resetsAt"), "five_hour.resetsAt")
elapsed_seconds = 5 * 3600 - (resets - generated).total_seconds()

pace = pace_burn(week)
if elapsed_seconds >= 30 * 60:
    pace = max(pace, pace_burn(five))

cap = base
if five_pct < 25 or pace > 1.15:
    cap = min(cap, 2)
if five_pct <= 15 or pace > 1.5:
    cap = min(cap, 1)

codex_pace = codex_week.get("pace") if isinstance(codex_week.get("pace"), dict) else {}
codex_spawn = "no" if codex_pace.get("status") == "ahead" else "yes"

print(f"effective_cap: {cap}")
print(f"codex_spawn: {codex_spawn}")
print(f"claude_pace: {pace:.2f}")
PY
