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
#                                 [--accounts-jsonl <file>]
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
#   --accounts-jsonl <f> evaluate every account in <f>, the
#                        `bin/fm-claude-account-quota.sh --snapshots` lines,
#                        instead of reading them; the multi-account test seam.
#                        FM_DISPATCH_ACCOUNTS_JSONL sets it from the
#                        environment. A --quota-json given with it supplies
#                        only the codex provider.
#   --state-dir <dir>    count live lanes in <dir> instead of $FM_HOME/state.
#
# Bound account: without --claude-account or a --quota-json fixture, the
# account is the one config/claude-account pins (read the way
# bin/fm-quota-choose.sh's --claude-profile-snapshot reads it), or `ordinary`
# when the home declares no pin. quota-axi is always run for that account,
# never for the ambient login of the process that happens to call this
# script.
#
# Several accounts: with no --claude-account and no --quota-json, a home that
# declares config/claude-accounts (docs/configuration.md "Several Claude
# accounts") has every declared entry measured in isolation through
# bin/fm-claude-account-quota.sh --snapshots, and the rules below are applied
# to each account separately, its lanes counted by its own account=. The
# effective cap is then the sum of the per-account caps, never above the base
# cap, so one exhausted account no longer zeroes the home while another has
# headroom. An account whose reading cannot be taken counts as tight (cap 1).
# Without the list, nothing here changes. The list together with
# config/claude-account is refused, as every Claude launch refuses it.
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
#   projectedExhaustedAt < resetsAt - 20m, and the projection is not
#     flagged `early`                                         -> cap 0
#   five_hour.percentRemaining < 40                           -> cap 1
#   the reading cannot be taken or is a rate-limited/auth state -> cap 1
# The projection is linear, so an account burning exactly on pace projects
# exhaustion at the reset itself; only exhaustion materially before the
# reset (by more than 20 minutes) blocks, and an `early` projection is never
# used because it swings by hours in a window's first 10%. On-pace spend
# keeps its lanes right up to the reset.
# A projection is always a forecast: the readout below labels it `est.` and
# omits it while `early`. The plain facts - the account, the five_hour and
# seven_day percentages left, their reset times, and when the reading was
# taken - are printed separately and never reworded as a verdict.
# cap 0 queues every new Claude lane; cap 1 admits new lanes only while no
# implementing Claude lane is on that account. Lanes are counted from
# state/*.meta records (harness=claude, kind not secondmate, matching
# account=, no pr= handoff recorded, the same occupancy rule as
# bin/fm-project-capacity-lib.sh); a secondmate holds no dispatched lane and
# is exempt. The count is advisory under concurrent spawns: it takes no lock. A missing
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
#   claude_reading: available|unavailable
#   claude_five_hour_percent_remaining: <n|->  (fact)
#   claude_five_hour_resets_at: <iso|->        (fact)
#   claude_seven_day_percent_remaining: <n|->  (fact)
#   claude_seven_day_resets_at: <iso|->        (fact)
#   claude_read_at: <iso|->                    (fact: when quota-axi read it)
#   claude_exhaustion_estimate: est. <iso> | - (forecast; `-` while early)
#   claude_lanes: <n>
#   claude_runway_cap: none|0|1
#   claude_runway_block: yes|no
#   claude_runway_reason: <one line>
# With several declared accounts, the single-account claude_* lines are
# replaced by:
#   claude_accounts: <n declared>
#   claude_headroom_accounts: <comma list of accounts with lanes < cap | ->
#   claude_account_row: <entry>  cap=<n>  lanes=<n>  runway_cap=none|0|1
#     runway_block=yes|no  reading=available|unavailable
#     five_hour_percent_remaining=<n|->  five_hour_resets_at=<iso|->
#     seven_day_percent_remaining=<n|->  seven_day_resets_at=<iso|->
#     read_at=<iso|->  exhaustion_estimate=est. <iso>|-  reason=<one line>
#   (one claude_account_row line per declared account, in file order, fields
#   separated by two spaces); claude_pace is the largest across accounts.
#
# Exit codes: 0 on success; 2 when config/dispatch-cap is malformed, a
# supplied --quota-json document is malformed or lacks the claude row the
# ladder reads, config/claude-account is unreadable, config/claude-accounts
# is refused by bin/fm-worker-account-lib.sh, or both account files exist. A reading that cannot
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
ACCOUNTS_JSONL=${FM_DISPATCH_ACCOUNTS_JSONL:-}
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
    --accounts-jsonl)
      ACCOUNTS_JSONL="${2:?--accounts-jsonl needs a value}"
      if [ ! -f "$ACCOUNTS_JSONL" ]; then
        echo "fm-dispatch-quota-cap: --accounts-jsonl file does not exist: $ACCOUNTS_JSONL" >&2
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

# Several declared accounts: with no --claude-account and no --quota-json, a
# home that keeps config/claude-accounts is measured account by account
# through bin/fm-claude-account-quota.sh --snapshots instead of one bound
# account. --accounts-jsonl supplies those lines directly.
MULTI=0
LISTED=
ACCOUNTS_DOC=
if [ -n "$ACCOUNTS_JSONL" ]; then
  MULTI=1
  ACCOUNTS_DOC=$(cat -- "$ACCOUNTS_JSONL") || {
    echo "fm-dispatch-quota-cap: cannot read $ACCOUNTS_JSONL" >&2
    exit 2
  }
elif [ -z "$CLAUDE_ACCOUNT" ] && [ -z "$QUOTA_JSON" ]; then
  # shellcheck source=bin/fm-worker-account-lib.sh
  . "$SCRIPT_DIR/fm-worker-account-lib.sh"
  LISTED=$(fm_worker_account_list claude "$CONFIG") || exit 2
  if [ -n "$LISTED" ]; then
    if [ -e "$CONFIG/claude-account" ]; then
      echo "fm-dispatch-quota-cap: config/claude-accounts and config/claude-account are both present; a home keeps only one" >&2
      exit 2
    fi
    MULTI=1
    ACCOUNTS_DOC=$(FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-claude-account-quota.sh" --snapshots 2>/dev/null) || ACCOUNTS_DOC=
  fi
fi

# Resolve the bound account: an explicit argument wins, then the pin file the
# way bin/fm-quota-choose.sh reads it, then the home's ordinary account.
if [ "$MULTI" = 1 ]; then
  CLAUDE_ACCOUNT=
elif [ -z "$CLAUDE_ACCOUNT" ]; then
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
case "$MULTI:$CLAUDE_ACCOUNT" in
  1:* | 0:ordinary | 0:/*) ;;
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
elif [ -z "$ACCOUNTS_JSONL" ]; then
  if command -v quota-axi >/dev/null 2>&1; then
    if [ "$MULTI" = 1 ]; then
      :
    elif [ "$CLAUDE_ACCOUNT" = ordinary ]; then
      CLAUDE_DOC=$( (unset CLAUDE_CONFIG_DIR; fm_run_timed "$DEFAULT_QUOTA_SECONDS" quota-axi --provider claude --json --full) 2>/dev/null) || true
    else
      CLAUDE_DOC=$(CLAUDE_CONFIG_DIR="$CLAUDE_ACCOUNT" fm_run_timed "$DEFAULT_QUOTA_SECONDS" quota-axi --provider claude --profile-only --json --full 2>/dev/null) || true
    fi
    CODEX_DOC=$( (unset CLAUDE_CONFIG_DIR; fm_run_timed "$DEFAULT_QUOTA_SECONDS" quota-axi --provider codex --json) 2>/dev/null) || true
  fi
fi

FM_CAP_BASE="$base" FM_CAP_DOC="$DOC" FM_CAP_CLAUDE_DOC="$CLAUDE_DOC" \
  FM_CAP_CODEX_DOC="$CODEX_DOC" FM_CAP_FIXTURE="$FIXTURE" \
  FM_CAP_ACCOUNT="$CLAUDE_ACCOUNT" FM_CAP_STATE="$STATE" \
  FM_CAP_MULTI="$MULTI" FM_CAP_LISTED="$LISTED" FM_CAP_ACCOUNTS_DOC="$ACCOUNTS_DOC" python3 <<'PY'
import glob
import json
import os
import re
import sys
from datetime import datetime, timedelta

base = int(os.environ["FM_CAP_BASE"])
state = os.environ["FM_CAP_STATE"]
bound_account = os.environ["FM_CAP_ACCOUNT"]
fixture = os.environ["FM_CAP_FIXTURE"] == "1"
multi = os.environ["FM_CAP_MULTI"] == "1"

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

def schema5_providers(source):
    if isinstance(source, dict) and source.get("schemaVersion") == 5 \
            and isinstance(source.get("providers"), list):
        return [p for p in source["providers"] if isinstance(p, dict)]
    return []

def provider_named(providers, name):
    for provider in providers:
        if provider.get("provider") == name:
            return provider
    return None

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
    providers = schema5_providers(claude_doc) + schema5_providers(codex_doc)

codex = provider_named(providers, "codex")

def meta_value(path, key):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if line.startswith(key + "="):
                    return line[len(key) + 1:].rstrip("\n")
    except OSError:
        pass
    return ""

def count_lanes(account):
    lanes = 0
    for path in glob.glob(os.path.join(state, "*.meta")):
        if meta_value(path, "harness") != "claude":
            continue
        if meta_value(path, "kind") == "secondmate":
            continue
        if meta_value(path, "pr"):
            continue
        recorded = meta_value(path, "account")
        if account == "ordinary":
            if recorded in ("", "ordinary"):
                lanes += 1
        elif recorded == account:
            lanes += 1
    return lanes

def evaluate(account, claude, source_doc, strict):
    """Apply the ladder and runway rows to one account's claude row.

    strict refuses a malformed supplied fixture (the single-account seam);
    otherwise a malformed or missing reading is unavailable and tight."""
    lanes = count_lanes(account)
    unavailable = claude is None
    five = None
    seven = None
    five_pct = None
    generated = None
    read_at = None
    if claude is not None:
        status = (claude.get("state") or {}).get("status")
        if claude.get("notSetUp") or status in (
            "unavailable", "error", "auth_required", "rate_limited", "refused"
        ):
            unavailable = True
        five = window_by_id(claude, "five_hour")
        seven = window_by_id(claude, "seven_day")
        if five is None:
            if strict and not unavailable:
                refuse("quota document has no claude five_hour window")
            unavailable = True
        else:
            five_pct = number(five, "percentRemaining")
            if five_pct is None:
                if strict and not unavailable:
                    refuse("five_hour window has no numeric percentRemaining")
                unavailable = True
        generated = ts(source_doc.get("generatedAt")) if isinstance(source_doc, dict) else None
        read_at = ts((claude.get("state") or {}).get("refreshedAt")) or generated

    runway_cap = None
    reason = ""
    pace_burn_used = 0.0
    projected = None
    early = False
    five_resets = None
    seven_pct = None
    seven_resets = None

    if five is not None:
        five_resets = ts(five.get("resetsAt"))
    if seven is not None:
        seven_pct = number(seven, "percentRemaining")
        seven_resets = ts(seven.get("resetsAt"))

    def runway_confidence():
        semantics = claude.get("quotaSemantics") if isinstance(claude, dict) else None
        entries = semantics.get("effectiveAvailability") if isinstance(semantics, dict) else None
        for entry in entries if isinstance(entries, list) else []:
            runway = entry.get("runway") if isinstance(entry, dict) else None
            if not isinstance(runway, dict):
                continue
            ids = runway.get("limitingWindowIds")
            ids = ids if isinstance(ids, list) else [runway.get("limitingWindowId")]
            if "five_hour" in ids and runway.get("projectionConfidence") is not None:
                return runway["projectionConfidence"]
        return None

    if unavailable:
        runway_cap = 1
        reason = "quota reading unavailable; treated as tight"
    else:
        pace = five.get("pace") if isinstance(five.get("pace"), dict) else {}
        resets = five_resets
        if resets is None:
            if strict:
                refuse("five_hour window has no parseable resetsAt")
            unavailable = True
            runway_cap = 1
            reason = "quota reading unavailable; treated as tight"
        else:
            projected = ts(pace.get("projectedExhaustedAt"))
            if projected is None:
                projected = ts(five.get("projectedExhaustedAt"))
            confidence = pace.get("projectionConfidence")
            if confidence is None:
                confidence = runway_confidence()
            early = confidence == "early"
            exhausted_now = five_pct <= 0 or pace.get("status") == "exhausted_now"
            projected_first = (
                projected is not None
                and not early
                and projected < resets - timedelta(minutes=20)
            )
            if exhausted_now:
                runway_cap = 0
                reason = f"{five_pct:g}% left; five-hour window already exhausted"
            elif projected_first:
                runway_cap = 0
                reason = (
                    f"est. exhaustion {projected.isoformat()} is before the reset "
                    f"{resets.isoformat()} minus 20m"
                )
            elif five_pct < 40:
                runway_cap = 1
                reason = f"{five_pct:g}% left (< 40); one implementing lane allowed on this account"
            else:
                runway_cap = None
                if projected is None:
                    reason = f"healthy: {five_pct:g}% left, no projected exhaustion"
                elif early:
                    reason = f"healthy: {five_pct:g}% left, projection omitted (early)"
                else:
                    reason = f"healthy: {five_pct:g}% left, est. exhaustion {projected.isoformat()}"
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

    return {
        "account": account,
        "cap": cap,
        "lanes": lanes,
        "unavailable": unavailable,
        "five_pct": five_pct,
        "five_resets": five_resets,
        "seven_pct": seven_pct,
        "seven_resets": seven_resets,
        "read_at": read_at,
        "projected": projected,
        "early": early,
        "runway_cap": runway_cap,
        "block": runway_cap is not None and lanes >= runway_cap,
        "reason": reason,
        "pace": pace_burn_used,
    }

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

def fmt_num(value):
    return "-" if value is None else f"{value:g}"

def fmt_ts(value):
    return "-" if value is None else value.isoformat()

def estimate(result):
    if result["projected"] is not None and not result["early"]:
        return f"est. {result['projected'].isoformat()}"
    return "-"

def flat(value):
    return re.sub(r"[\t\r\n]", " ", str(value))

if multi:
    # One reading per declared account; a line that is not a usable JSON
    # object for a declared account leaves that account unavailable (tight).
    rows = {}
    order = []
    for line in os.environ.get("FM_CAP_ACCOUNTS_DOC", "").splitlines():
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict) or not isinstance(entry.get("account"), str):
            continue
        if entry["account"] not in rows:
            order.append(entry["account"])
        rows[entry["account"]] = entry
    listed = [a for a in os.environ.get("FM_CAP_LISTED", "").splitlines() if a]
    accounts = listed or order
    if not accounts:
        refuse("no declared Claude account to measure")
    results = []
    for account in accounts:
        entry = rows.get(account) or {}
        snapshot = entry.get("snapshot") if not entry.get("error") else None
        claude = provider_named(schema5_providers(snapshot), "claude")
        results.append(evaluate(account, claude, snapshot, False))
    total = min(base, sum(r["cap"] for r in results))
    headroom = [r["account"] for r in results if r["lanes"] < r["cap"]]
    print(f"effective_cap: {total}")
    print(f"codex_spawn: {codex_spawn}")
    print(f"claude_pace: {max(r['pace'] for r in results):.2f}")
    print(f"claude_accounts: {len(results)}")
    print(f"claude_headroom_accounts: {','.join(flat(a) for a in headroom) if headroom else '-'}")
    for r in results:
        print(
            f"claude_account_row: {flat(r['account'])}"
            f"  cap={r['cap']}"
            f"  lanes={r['lanes']}"
            f"  runway_cap={'none' if r['runway_cap'] is None else r['runway_cap']}"
            f"  runway_block={'yes' if r['block'] else 'no'}"
            f"  reading={'unavailable' if r['unavailable'] else 'available'}"
            f"  five_hour_percent_remaining={fmt_num(r['five_pct'])}"
            f"  five_hour_resets_at={fmt_ts(r['five_resets'])}"
            f"  seven_day_percent_remaining={fmt_num(r['seven_pct'])}"
            f"  seven_day_resets_at={fmt_ts(r['seven_resets'])}"
            f"  read_at={fmt_ts(r['read_at'])}"
            f"  exhaustion_estimate={estimate(r)}"
            f"  reason={flat(r['reason'])}"
        )
    sys.exit(0)

claude = provider_named(providers, "claude")
if fixture and claude is None:
    refuse("quota document has no claude provider")
r = evaluate(bound_account, claude, doc if fixture else claude_doc, fixture)

print(f"effective_cap: {r['cap']}")
print(f"codex_spawn: {codex_spawn}")
print(f"claude_pace: {r['pace']:.2f}")
print(f"claude_account: {bound_account}")
print(f"claude_reading: {'unavailable' if r['unavailable'] else 'available'}")
print(f"claude_five_hour_percent_remaining: {fmt_num(r['five_pct'])}")
print(f"claude_five_hour_resets_at: {fmt_ts(r['five_resets'])}")
print(f"claude_seven_day_percent_remaining: {fmt_num(r['seven_pct'])}")
print(f"claude_seven_day_resets_at: {fmt_ts(r['seven_resets'])}")
print(f"claude_read_at: {fmt_ts(r['read_at'])}")
print(f"claude_exhaustion_estimate: {estimate(r)}")
print(f"claude_lanes: {r['lanes']}")
print(f"claude_runway_cap: {'none' if r['runway_cap'] is None else r['runway_cap']}")
print(f"claude_runway_block: {'yes' if r['block'] else 'no'}")
print(f"claude_runway_reason: {r['reason']}")
PY
