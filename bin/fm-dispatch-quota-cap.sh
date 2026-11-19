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
#                                 [--claude-account <ordinary|/path>]
#                                 [--state-dir <dir>]
#   --quota-json <file>  read the `quota-axi --json` document from <file>
#                        instead of running quota-axi; the test seam and
#                        offline replay use this. The file must carry
#                        schemaVersion 5, and its claude provider is the
#                        bound account's row. FM_DISPATCH_QUOTA_JSON sets
#                        the same seam from the environment so bin/fm-spawn.sh
#                        can exercise its refusal in tests.
#   --claude-account <v> evaluate this bound account instead of reading
#                        config/claude-account: `ordinary` (CLAUDE_CONFIG_DIR
#                        unset, this home's ordinary account) or one absolute
#                        Claude config directory.
#   --state-dir <dir>    count live lanes in <dir> instead of $FM_HOME/state.
#
# Bound account: without --claude-account or a --quota-json fixture, the
# account is the one config/claude-account pins (read the way
# bin/fm-quota-choose.sh's --claude-profile-snapshot reads it), or `ordinary`
# when the home declares no pin. quota-axi is always run for that account,
# never for the ambient login of the process that happens to call this
# script.
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
#
# Per-account 5-hour runway admission (the bound account's own five_hour
# window, report section 5 of data/claude-5h-window-system/report.md):
#   projectedExhaustedAt < resetsAt + 20m                     -> cap 0
#   five_hour.percentRemaining < 40                           -> cap 1
#   the reading cannot be taken or is a rate-limited/auth state -> cap 1
# cap 0 queues every new Claude lane; cap 1 admits new lanes only while no
# live Claude lane is on that account. Live lanes are counted from
# state/*.meta records (harness=claude, kind not secondmate, matching
# account=); a secondmate holds no dispatched lane and is exempt. A missing
# projectedExhaustedAt falls through to the percent row rather than reading
# as headroom. The per-account cap is also folded into effective_cap, so the
# /autonomous pass stops offering Claude lanes at the same point.
# Codex: codex_spawn is "no" whenever the codex provider's weekly window
# reports pace.status "ahead"; "yes" otherwise. The weekly window is found by
# kind/id (weekly) or by a `window:<hours>h` id of at least a week, which is
# how quota-axi names the Codex window (`window:720h`). A missing Codex
# provider or window is optional evidence and leaves codex_spawn "yes"
# instead of refusing the whole gate.
#
# Output ("key: value" lines, stable order):
#   effective_cap: <n>
#   codex_spawn: yes|no
#   claude_pace: <burnMultiple the pace rows used, 0.00 when none applied>
#   claude_account: <ordinary|/path>
#   claude_lanes: <n>
#   claude_runway_cap: none|0|1
#   claude_runway_block: yes|no
#   claude_runway_reason: <one line>
#
# Exit codes: 0 on success; 2 when config/dispatch-cap is malformed, a
# supplied --quota-json document is malformed or lacks the claude row the
# ladder reads, or config/claude-account is unreadable. A reading that cannot
# be taken is not a usage error: it reports cap 1 ("tight") and exits 0,
# never exit 2 and never headroom.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

DEFAULT_BASE_CAP=3
DEFAULT_QUOTA_SECONDS=${FM_DISPATCH_QUOTA_SECONDS:-45}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

QUOTA_JSON=${FM_DISPATCH_QUOTA_JSON:-}
CLAUDE_ACCOUNT=
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
    --claude-account)
      CLAUDE_ACCOUNT="${2:?--claude-account needs a value}"
      shift 2
      ;;
    --state-dir)
      STATE="${2:?--state-dir needs a value}"
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

# Resolve the bound account: an explicit argument wins, then the pin file the
# way bin/fm-quota-choose.sh reads it, then the home's ordinary account.
if [ -z "$CLAUDE_ACCOUNT" ]; then
  if [ -e "$CONFIG/claude-account" ]; then
    # shellcheck source=bin/fm-worker-account-lib.sh
    . "$SCRIPT_DIR/fm-worker-account-lib.sh"
    selection=$(fm_worker_account_resolve claude "$CONFIG" "config/claude-account") || exit 2
    if [ -n "$selection" ]; then
      CLAUDE_ACCOUNT=${selection%%$'\t'*}
    else
      CLAUDE_ACCOUNT=ordinary
    fi
  else
    CLAUDE_ACCOUNT=ordinary
  fi
fi
case "$CLAUDE_ACCOUNT" in
  ordinary | /*) ;;
  *)
    echo "fm-dispatch-quota-cap: bound account must be ordinary or one absolute Claude config directory, got: $CLAUDE_ACCOUNT" >&2
    exit 2
    ;;
esac

FIXTURE=0
DOC=
CLAUDE_DOC=
CODEX_DOC=
if [ -n "$QUOTA_JSON" ]; then
  FIXTURE=1
  DOC=$(cat -- "$QUOTA_JSON") || {
    echo "fm-dispatch-quota-cap: cannot read $QUOTA_JSON" >&2
    exit 2
  }
else
  if command -v quota-axi >/dev/null 2>&1; then
    if [ "$CLAUDE_ACCOUNT" = ordinary ]; then
      CLAUDE_DOC=$( (unset CLAUDE_CONFIG_DIR; fm_run_timed "$DEFAULT_QUOTA_SECONDS" quota-axi --provider claude --json --full) 2>/dev/null) || true
    else
      CLAUDE_DOC=$(CLAUDE_CONFIG_DIR="$CLAUDE_ACCOUNT" fm_run_timed "$DEFAULT_QUOTA_SECONDS" quota-axi --provider claude --profile-only --json --full 2>/dev/null) || true
    fi
    CODEX_DOC=$( (unset CLAUDE_CONFIG_DIR; fm_run_timed "$DEFAULT_QUOTA_SECONDS" quota-axi --provider codex --json) 2>/dev/null) || true
  fi
fi

FM_CAP_BASE="$base" FM_CAP_DOC="$DOC" FM_CAP_CLAUDE_DOC="$CLAUDE_DOC" \
  FM_CAP_CODEX_DOC="$CODEX_DOC" FM_CAP_FIXTURE="$FIXTURE" \
  FM_CAP_ACCOUNT="$CLAUDE_ACCOUNT" FM_CAP_STATE="$STATE" python3 <<'PY'
import glob
import json
import os
import re
import sys
from datetime import datetime, timedelta

base = int(os.environ["FM_CAP_BASE"])
state = os.environ["FM_CAP_STATE"]
account = os.environ["FM_CAP_ACCOUNT"]
fixture = os.environ["FM_CAP_FIXTURE"] == "1"

def refuse(msg):
    print(f"fm-dispatch-quota-cap: {msg}", file=sys.stderr)
    sys.exit(2)

def load(name):
    raw = os.environ.get(name, "")
    if not raw.strip():
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return None

def ts(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None

def number(window, key):
    value = window.get(key) if isinstance(window, dict) else None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)

def window_by_id(provider, wid):
    if not isinstance(provider, dict):
        return None
    for win in provider.get("windows", []):
        if isinstance(win, dict) and win.get("id") == wid:
            return win
    return None

def pace_burn(window):
    pace = window.get("pace") if isinstance(window, dict) else None
    if not isinstance(pace, dict) or pace.get("status") != "ahead":
        return 0.0
    burn = pace.get("burnMultiple")
    return float(burn) if isinstance(burn, (int, float)) and not isinstance(burn, bool) else 0.0

doc = load("FM_CAP_DOC")
claude_doc = load("FM_CAP_CLAUDE_DOC")
codex_doc = load("FM_CAP_CODEX_DOC")

if fixture:
    if not isinstance(doc, dict):
        refuse("quota document is not a JSON object")
    if doc.get("schemaVersion") != 5:
        refuse(f"expected quota-axi schemaVersion 5, got: {doc.get('schemaVersion')!r}")
    if not isinstance(doc.get("providers"), list):
        refuse("quota document has no providers list")
    providers = [p for p in doc["providers"] if isinstance(p, dict)]
else:
    providers = []
    for source in (claude_doc, codex_doc):
        if isinstance(source, dict) and source.get("schemaVersion") == 5 \
                and isinstance(source.get("providers"), list):
            providers.extend(p for p in source["providers"] if isinstance(p, dict))

def provider_named(name):
    for provider in providers:
        if provider.get("provider") == name:
            return provider
    return None

claude = provider_named("claude")
codex = provider_named("codex")
if fixture and claude is None:
    refuse("quota document has no claude provider")

def meta_value(path, key):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if line.startswith(key + "="):
                    return line[len(key) + 1:].rstrip("\n")
    except OSError:
        pass
    return ""

lanes = 0
for path in glob.glob(os.path.join(state, "*.meta")):
    if meta_value(path, "harness") != "claude":
        continue
    if meta_value(path, "kind") == "secondmate":
        continue
    recorded = meta_value(path, "account")
    if account == "ordinary":
        if recorded in ("", "ordinary"):
            lanes += 1
    elif recorded == account:
        lanes += 1

unavailable = claude is None
five = None
seven = None
five_pct = None
generated = None
if claude is not None:
    status = (claude.get("state") or {}).get("status")
    if claude.get("notSetUp") or status in (
        "unavailable", "error", "auth_required", "rate_limited", "refused"
    ):
        unavailable = True
    five = window_by_id(claude, "five_hour")
    seven = window_by_id(claude, "seven_day")
    if five is None:
        if fixture:
            refuse("quota document has no claude five_hour window")
        unavailable = True
    else:
        five_pct = number(five, "percentRemaining")
        if five_pct is None:
            if fixture:
                refuse("five_hour window has no numeric percentRemaining")
            unavailable = True
    source_doc = doc if fixture else claude_doc
    generated = ts(source_doc.get("generatedAt")) if isinstance(source_doc, dict) else None

runway_cap = None
reason = ""
pace_burn_used = 0.0

if unavailable:
    runway_cap = 1
    reason = "quota reading unavailable; treated as tight"
else:
    pace = five.get("pace") if isinstance(five.get("pace"), dict) else {}
    resets = ts(five.get("resetsAt"))
    if resets is None:
        if fixture:
            refuse("five_hour window has no parseable resetsAt")
        unavailable = True
        runway_cap = 1
        reason = "quota reading unavailable; treated as tight"
    else:
        projected = ts(pace.get("projectedExhaustedAt"))
        if projected is None:
            projected = ts(five.get("projectedExhaustedAt"))
        exhausted_now = five_pct <= 0 or pace.get("status") == "exhausted_now"
        projected_first = projected is not None and projected < resets + timedelta(minutes=20)
        if exhausted_now:
            runway_cap = 0
            reason = f"{five_pct:g}% left; five-hour window already exhausted"
        elif projected_first:
            runway_cap = 0
            reason = (
                f"projected exhaustion {projected.isoformat()} is before the reset "
                f"{resets.isoformat()} plus 20m"
            )
        elif five_pct < 40:
            runway_cap = 1
            reason = f"{five_pct:g}% left (< 40); one implementing lane allowed on this account"
        else:
            runway_cap = None
            if projected is None:
                reason = f"healthy: {five_pct:g}% left, no projected exhaustion"
            else:
                reason = f"healthy: {five_pct:g}% left, projection {projected.isoformat()} after reset"
        if five is not None and seven is not None:
            pace_burn_used = pace_burn(seven)
        if five is not None and generated is not None and seven is not None:
            elapsed = 5 * 3600 - (resets - generated).total_seconds()
            if elapsed >= 30 * 60:
                pace_burn_used = max(pace_burn_used, pace_burn(five))

cap = base
if unavailable:
    cap = min(cap, 1)
else:
    if five_pct < 25 or pace_burn_used > 1.15:
        cap = min(cap, 2)
    if five_pct <= 15 or pace_burn_used > 1.5:
        cap = min(cap, 1)
if runway_cap is not None:
    cap = min(cap, runway_cap)

block = runway_cap is not None and lanes >= runway_cap

def codex_weekly(provider):
    if not isinstance(provider, dict):
        return None
    for win in provider.get("windows", []):
        if not isinstance(win, dict):
            continue
        if win.get("id") == "weekly" or win.get("kind") == "weekly":
            return win
    for win in provider.get("windows", []):
        if not isinstance(win, dict):
            continue
        match = re.fullmatch(r"window:([0-9]+(?:\.[0-9]+)?)h", str(win.get("id", "")))
        if match and float(match.group(1)) >= 168:
            return win
    return None

codex_window = codex_weekly(codex) if codex is not None and not codex.get("notSetUp") else None
codex_pace = (codex_window or {}).get("pace") if isinstance(codex_window, dict) else None
codex_spawn = "no" if isinstance(codex_pace, dict) and codex_pace.get("status") == "ahead" else "yes"

print(f"effective_cap: {cap}")
print(f"codex_spawn: {codex_spawn}")
print(f"claude_pace: {pace_burn_used:.2f}")
print(f"claude_account: {account}")
print(f"claude_lanes: {lanes}")
print(f"claude_runway_cap: {'none' if runway_cap is None else runway_cap}")
print(f"claude_runway_block: {'yes' if block else 'no'}")
print(f"claude_runway_reason: {reason}")
PY
