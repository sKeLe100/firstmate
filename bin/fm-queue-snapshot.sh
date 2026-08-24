#!/usr/bin/env bash
# fm-queue-snapshot.sh - deterministic, read-only snapshot of the next queued
# backlog items for the /queue skill.
#
# tasks-axi (bin/fm-tasks-axi-lib.sh's compatible binary) remains the single
# backlog source; this script never parses data/backlog.md itself and never
# reorders, filters, or mutates what tasks-axi returns. It shells out to
# `tasks-axi list --state queued --limit <N>` for the first N queued items in
# tasks-axi's own return order (the same order `tasks-axi ready` surfaces for
# the unblocked subset) and enriches each row with two more deterministic
# facts tasks-axi does not itself carry:
#
#   posture   - this item's project delivery mode/yolo, from
#               bin/fm-project-mode.sh (the single owner of data/projects.md
#               registry parsing; this script does not read that file
#               directly or invent a second registry reader).
#   autonomy  - captain-gated | autonomous-eligible | unclear, derived (never
#               guessed) as: captain-gated when the item's own kind is
#               "captain" or it carries a captain-kind hold, OR when its
#               project's registry posture has yolo off; autonomous-eligible
#               when none of those hold and yolo is on; unclear only when the
#               item carries no captain-kind signal AND no project (repo
#               empty/"-"), the one case this script cannot resolve
#               deterministically.
#
# Tier/model/effort resolution against a single item is deliberately OUT of
# scope: matching an item's description against config/crew-dispatch.json's
# natural-language `when` rules is judgment, the same judgment AGENTS.md
# section 4 gives to firstmate at real dispatch time, and a profile array's
# concrete pick additionally needs live quota-axi evidence this script must
# not spend PER ITEM on a 30-row listing. This script only reports whether
# config/crew-dispatch.json is present/absent/invalid/unverified so the caller
# knows whether tier matching is even possible; the caller (the /queue skill)
# reads the file itself and does the per-item matching. "present" means the
# file passes the shared crew-dispatch validity contract in
# bin/fm-crew-dispatch-lib.sh - the same verdict bin/fm-bootstrap.sh reports as
# CREW_DISPATCH - not merely that it parses as JSON, so the skill never
# publishes tiers from a config real dispatch would refuse. "unverified" means
# that contract could not be evaluated here because jq is unavailable; the
# caller must treat it as untrustworthy for tiers rather than guessing.
#
# This script DOES spend one bounded, aggregate quota-axi read per invocation
# for the hierarchy header below (never per queued item): a single
# `quota-axi --json` call to report live lane availability. It runs no
# tasks-axi mutation and writes no file.
#
# Ranking and priority: items are sorted by tasks-axi's own `priority` field
# (0-4, higher = more urgent), descending, BEFORE --limit is applied, so a
# high-priority item outside the first N in tasks-axi's raw return order is
# never dropped from view. An item with no priority set ("-") sorts as the
# lowest priority. Equal-priority items (including all items when none set a
# priority) keep tasks-axi's own return order as a stable tiebreak - this
# script never reorders same-priority items by title, id, or any other guess.
# `rank` is the resulting 1-based position after that sort, the same number
# the /queue skill renders so the captain's item numbers match this script's
# order exactly.
#
# Usage: fm-queue-snapshot.sh [--limit N]   (default N=30)
#
# Output (stable field order; the rows are RFC4180 CSV, so an embedded quote is
# doubled - "" - not backslash-escaped as tasks-axi's own TOON input is, and a
# newline, carriage return, or tab inside a value is written back as the literal
# two-character \n, \r, or \t - with any literal backslash doubled to \\ so those
# escapes stay unambiguous - so every item stays on exactly one LF-terminated
# line):
#   count: <n>
#   items[<n>]{rank,id,title,kind,repo,priority,blocked,blocked_by,held,hold_kind,hold_reason,hold_until,posture,autonomy,autonomy_reason}:
#     <csv row>...
#   dispatch_config: absent|present|invalid|unverified
#   hierarchy_lanes: unavailable (dispatch_config: <status>)
#     -- OR "unavailable (config defines no dispatch profiles)" when the
#     config is present but names no rule/default profile at all --
#     -- OR, only when dispatch_config is "present" and it names profiles --
#   hierarchy_lanes[<n>]{source,for,harness,model,effort,available,availability_reason}:
#     <csv row>...
#     `source` is "rule" (one row per config rule, `for` = that rule's own
#     `when` text) or "default" (`for` = "default (no rule matched)"); a rule
#     or default with a profile array yields one row per candidate profile,
#     never a collapsed summary. `model`/`effort` are "-" when the profile
#     omits them. `available` is yes/no/unknown: unknown means quota-axi
#     produced no evidence for that harness (not installed/authenticated, or
#     this script has no provider mapping for it) - never guessed as yes or
#     no. A lane with a model is bound by whichever is lower of that model's
#     own "model:<name>" scoped availability and the account-wide all_models
#     number, and the reason names that binding scope, so neither a
#     model-exhausted lane nor an exhausted account is ever reported
#     available on the other one's headroom. This block never lists a lane firstmate's dispatch config does not
#     itself configure, so a harness with no configured rule (a retired
#     subscription, for example) never appears here.
#   live_slots: <n>
#     count of state/*.meta entries currently tracked (spawned, not yet torn
#     down) in this FM_HOME - not a live/dead endpoint check, which is a
#     heavier, backend-process-dependent read already owned by
#     bin/fm-crew-state.sh and bin/fm-session-start.sh's own fleet-state
#     digest; this script deliberately does not duplicate that classifier.
#     Firstmate has no configured concurrency cap by default (AGENTS.md
#     section 7), so this script never reports one.
#
# Fails loudly (exit 1) when tasks-axi is missing or its list call errors,
# rather than reporting an empty queue that might just be a broken lookup.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,100p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

LIMIT=30
while [ $# -gt 0 ]; do
  case "$1" in
    --limit)
      LIMIT="${2:?--limit needs a value}"
      case "$LIMIT" in
        ''|*[!0-9]*)
          echo "fm-queue-snapshot: --limit needs a positive integer, got: $LIMIT" >&2
          exit 2
          ;;
      esac
      if [ "$LIMIT" -lt 1 ]; then
        echo "fm-queue-snapshot: --limit needs a positive integer, got: $LIMIT" >&2
        exit 2
      fi
      shift 2
      ;;
    *)
      echo "fm-queue-snapshot: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if ! command -v tasks-axi >/dev/null 2>&1; then
  echo "fm-queue-snapshot: tasks-axi not found on PATH" >&2
  exit 1
fi

TMP_LIST="$(mktemp "${TMPDIR:-/tmp}/fm-queue-snapshot.XXXXXX")"
TMP_ERR="$(mktemp "${TMPDIR:-/tmp}/fm-queue-snapshot-err.XXXXXX")"
trap 'rm -f "$TMP_LIST" "$TMP_ERR"' EXIT

FIELDS="blocked,blocked_by,held,hold_kind,hold_reason,hold_until,priority"
# Fetch every queued item (no --limit) so priority sorting below considers
# the full queue before the requested N is applied; --limit here would
# truncate to tasks-axi's raw return order first and could drop a
# high-priority item that falls outside the first N in that raw order.
if ! (cd "$FM_HOME" && tasks-axi list --state queued --fields "$FIELDS") \
  > "$TMP_LIST" 2> "$TMP_ERR"; then
  echo "fm-queue-snapshot: tasks-axi list failed: $(cat "$TMP_ERR")" >&2
  exit 1
fi

# shellcheck source=bin/fm-crew-dispatch-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-crew-dispatch-lib.sh"

CFG="$FM_HOME/config/crew-dispatch.json"
if [ ! -f "$CFG" ]; then
  dispatch_status=absent
else
  set +e
  fm_crew_dispatch_validate "$CFG" >/dev/null 2>&1
  cfg_rc=$?
  set -e
  case "$cfg_rc" in
    0) dispatch_status=present ;;
    2)
      if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CFG" >/dev/null 2>&1; then
        dispatch_status=unverified
      else
        dispatch_status=invalid
      fi
      ;;
    *) dispatch_status=invalid ;;
  esac
fi

PROJECT_MODE_BIN="$SCRIPT_DIR/fm-project-mode.sh"

FM_QUEUE_PROJECT_MODE_BIN="$PROJECT_MODE_BIN" \
FM_QUEUE_DISPATCH_STATUS="$dispatch_status" \
FM_QUEUE_LIMIT="$LIMIT" \
FM_QUEUE_CFG="$CFG" \
FM_QUEUE_STATE_DIR="$FM_HOME/state" \
python3 - "$TMP_LIST" <<'PY'
import csv
import glob
import json
import os
import subprocess
import sys

project_mode_bin = os.environ["FM_QUEUE_PROJECT_MODE_BIN"]
dispatch_status = os.environ["FM_QUEUE_DISPATCH_STATUS"]
limit = int(os.environ["FM_QUEUE_LIMIT"])
cfg_path = os.environ["FM_QUEUE_CFG"]
state_dir = os.environ["FM_QUEUE_STATE_DIR"]

TOON_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"'}


def one_line(value):
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace(
        "\r", "\\r").replace("\t", "\\t")


def split_toon_row(line):
    fields = []
    value = []
    quoted = False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == '"' and not value and not quoted:
            quoted = True
        elif quoted and ch == "\\" and i + 1 < len(line):
            nxt = line[i + 1]
            value.append(TOON_ESCAPES.get(nxt, nxt))
            i += 1
        elif quoted and ch == '"':
            quoted = False
        elif not quoted and ch == ",":
            fields.append("".join(value))
            value = []
        else:
            value.append(ch)
        i += 1
    fields.append("".join(value))
    return fields


WANTED = ("id", "title", "kind", "repo", "priority", "blocked", "blocked_by",
          "held", "hold_kind", "hold_reason", "hold_until")

rows = []
columns = None
reported_count = None
in_block = False
with open(sys.argv[1], encoding="utf-8") as fh:
    lines = fh.readlines()
for line in lines:
    line = line.rstrip("\n")
    if not in_block and line.startswith("count:"):
        head = line.split(":", 1)[1].strip().split()
        try:
            reported_count = int(head[0]) if head else None
        except ValueError:
            reported_count = None
        continue
    if line.startswith("tasks["):
        header = line[line.index("{") + 1:line.rindex("}")] if "{" in line and "}" in line else ""
        columns = [c.strip() for c in header.split(",") if c.strip()]
        missing = [c for c in WANTED if c not in columns]
        if missing:
            sys.exit(
                "fm-queue-snapshot: tasks-axi list header is missing "
                + ", ".join(missing)
            )
        in_block = True
        continue
    if line.startswith("help["):
        in_block = False
        continue
    if not in_block or not line.startswith("  ") or columns is None:
        continue
    fields = split_toon_row(line.strip())
    if len(fields) < len(columns):
        continue
    rows.append({name: fields[columns.index(name)] for name in WANTED})

if reported_count is None:
    sys.exit("fm-queue-snapshot: tasks-axi list printed no count line")
if reported_count != len(rows):
    sys.exit(
        "fm-queue-snapshot: parsed %d of tasks-axi's %d queued items; refusing to "
        "report a short queue" % (len(rows), reported_count)
    )

posture_cache = {}


def posture_for(repo):
    if repo in posture_cache:
        return posture_cache[repo]
    try:
        out = subprocess.run(
            [project_mode_bin, repo], capture_output=True, text=True, check=False
        ).stdout.strip()
        posture = out if out else "no-mistakes off"
    except OSError:
        posture = "no-mistakes off"
    posture_cache[repo] = posture
    return posture


def priority_key(value):
    return int(value) if value.isdigit() else -1


# Stable sort by descending priority; equal-priority items (including "-",
# the lowest bucket) keep tasks-axi's own return order as the tiebreak, since
# `rows` is already in that order and Python's sort is stable.
ranked_rows = sorted(rows, key=lambda r: -priority_key(r["priority"]))[:limit]

out_rows = []
for rank, r in enumerate(ranked_rows, start=1):
    captain_kind = r["kind"] == "captain" or r["hold_kind"] == "captain"
    repo = r["repo"]
    has_repo = bool(repo) and repo != "-"
    posture = posture_for(repo) if has_repo else "n/a"
    if captain_kind:
        autonomy, reason = "captain-gated", "captain kind or captain-kind hold"
    elif not has_repo:
        autonomy, reason = "unclear", "no project recorded on this item"
    else:
        yolo = posture.split()[-1] if posture else "off"
        if yolo == "off":
            autonomy, reason = "captain-gated", "project registry posture has yolo off"
        else:
            autonomy, reason = "autonomous-eligible", "project registry posture has yolo on"
    out_rows.append([
        rank, r["id"], r["title"], r["kind"], repo, r["priority"],
        r["blocked"], r["blocked_by"], r["held"], r["hold_kind"],
        r["hold_reason"], r["hold_until"], posture, autonomy, reason,
    ])

print(f"count: {len(out_rows)}")
if out_rows:
    cols = ("rank,id,title,kind,repo,priority,blocked,blocked_by,held,"
            "hold_kind,hold_reason,hold_until,posture,autonomy,autonomy_reason")
    print(f"items[{len(out_rows)}]{{{cols}}}:")
    writer = csv.writer(sys.stdout, lineterminator="\n")
    for row in out_rows:
        cells = [one_line(str(v)) for v in row]
        writer.writerow(["  " + cells[0]] + cells[1:])
print(f"dispatch_config: {dispatch_status}")

# --- hierarchy lanes: config/crew-dispatch.json rules/default enriched with
# one bounded, aggregate quota-axi read (never per queued item). -----------

HARNESS_TO_PROVIDER = {
    "claude": "claude",
    "codex": "codex",
    "grok": "grok",
    "kimi": "kimi",
}


QUOTA_TIMEOUT_SECONDS = 10


def profiles_of(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return [value]
    return []


def quota_lookup():
    try:
        proc = subprocess.run(
            ["quota-axi", "--json"], capture_output=True, text=True,
            check=False, timeout=QUOTA_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except (ValueError, TypeError):
        return None


def model_scope_token(scope):
    if not isinstance(scope, str) or not scope.startswith("model:"):
        return ""
    return scope.split(":", 1)[1].strip().lower()


def pick_model_scoped(availability, model):
    name = model.strip().lower()
    if not name:
        return None
    loose = None
    for entry in availability:
        token = model_scope_token(entry.get("scope"))
        if not token:
            continue
        if token == name:
            return entry
        if loose is None and (token in name or name in token):
            loose = entry
    return loose


def availability_for(harness, model, quota_data):
    provider_name = HARNESS_TO_PROVIDER.get(harness)
    if provider_name is None:
        return "unknown", "no quota-axi provider mapping for this worker runtime"
    if quota_data is None:
        return "unknown", "quota-axi produced no evidence"
    provider = next(
        (p for p in quota_data.get("providers", []) if p.get("provider") == provider_name),
        None,
    )
    if provider is None:
        return "unknown", f"no live quota data for {provider_name}"
    availability = (provider.get("quotaSemantics") or {}).get("effectiveAvailability") or []
    candidates = []
    scoped = pick_model_scoped(availability, model) if model else None
    if scoped is not None:
        candidates.append(scoped)
    account = next((a for a in availability if a.get("scope") == "all_models"), None)
    if account is not None:
        candidates.append(account)
    numeric = [
        a for a in candidates
        if isinstance(a.get("effectivePercentRemaining"), (int, float))
        and not isinstance(a.get("effectivePercentRemaining"), bool)
    ]
    if numeric:
        binding = min(numeric, key=lambda a: a["effectivePercentRemaining"])
        remaining = binding["effectivePercentRemaining"]
        verdict = "yes" if remaining > 0 else "no"
        return verdict, f"{remaining}% remaining ({binding.get('scope')})"
    windows = provider.get("windows") or []
    session = next((w for w in windows if w.get("kind") == "session"), None)
    window = session or (windows[0] if windows else None)
    if window is not None and window.get("percentRemaining") is not None:
        remaining = window["percentRemaining"]
        verdict = "yes" if remaining > 0 else "no"
        return verdict, f"{remaining}% remaining ({window.get('label', window.get('id'))})"
    return "unknown", f"no window evidence for {provider_name}"


if dispatch_status != "present":
    print(f"hierarchy_lanes: unavailable (dispatch_config: {dispatch_status})")
else:
    with open(cfg_path, encoding="utf-8") as fh:
        cfg = json.load(fh)
    lanes = []
    for rule in cfg.get("rules") or []:
        when = rule.get("when") or ""
        for profile in profiles_of(rule.get("use")):
            lanes.append(("rule", when, profile))
    for profile in profiles_of(cfg.get("default")):
        lanes.append(("default", "default (no rule matched)", profile))

    quota_data = quota_lookup() if lanes else None
    lane_rows = []
    for source, for_text, profile in lanes:
        harness = profile.get("harness", "")
        model = profile.get("model") or "-"
        effort = profile.get("effort") or "-"
        available, avail_reason = availability_for(
            harness, model if model != "-" else "", quota_data
        )
        lane_rows.append([source, for_text, harness, model, effort, available, avail_reason])

    if lane_rows:
        print(f"hierarchy_lanes[{len(lane_rows)}]{{source,for,harness,model,effort,available,availability_reason}}:")
        writer = csv.writer(sys.stdout, lineterminator="\n")
        for row in lane_rows:
            cells = [one_line(str(v)) for v in row]
            writer.writerow(["  " + cells[0]] + cells[1:])
    else:
        print("hierarchy_lanes: unavailable (config defines no dispatch profiles)")

live_slots = len(glob.glob(os.path.join(state_dir, "*.meta")))
print(f"live_slots: {live_slots}")
PY
