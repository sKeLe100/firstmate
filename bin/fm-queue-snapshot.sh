#!/usr/bin/env bash
# fm-queue-snapshot.sh - deterministic, read-only snapshot of the next queued
# backlog items for the /queue skill.
#
# tasks-axi (bin/fm-tasks-axi-lib.sh's compatible binary) remains the single
# backlog source; this script never parses data/backlog.md itself and never
# filters or mutates what tasks-axi returns, and reorders it only by the
# sorts documented under "Ranking and priority" below. It shells out
# to `tasks-axi list --state queued` for EVERY queued item (no --limit, so
# the sort sees the whole queue), sorts that set, keeps the top N, and
# enriches each surviving row with more deterministic facts tasks-axi
# does not itself carry:
#
#   rank      - the 1-based position after that sort (see "Ranking and
#               priority" below).
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
#               empty/"-") AND no id-prefix project inference (below)
#               resolved one either, the one case this script cannot resolve
#               deterministically.
#
# When repo is empty/"-", this script also asks bin/fm-project-mode.sh
# --infer-project-from-id whether the item's own id names a registered
# project by prefix (its name or a recorded alias; see that script's header
# for the exact match rule). A hit resolves posture/autonomy exactly as a
# recorded repo would and reports autonomy_reason "project inferred from id
# prefix" instead of "no project recorded on this item", so the skill can
# render it as an inferred verdict rather than "unclear". This is inference
# for THIS READ only - it never writes repo back to the backlog item.
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
# Ranking: whichever sort is in effect (gate class by default, or descending
# priority under --priority; see Usage below) is applied to the FULL queued
# set BEFORE --limit, so an item that would rank high is never dropped from
# view merely because tasks-axi returned it late. Under --priority, items are
# sorted by tasks-axi's own `priority` field (0-4, higher = more urgent),
# descending; an item with no priority set ("-") sorts as the lowest
# priority, and equal-priority items (including all items when none set a
# priority) keep tasks-axi's own return order as a stable tiebreak - this
# script never reorders same-priority items by title, id, or any other guess.
# `rank` is the resulting 1-based position after that sort, the same number
# the /queue skill renders so the captain's item numbers match this script's
# order exactly.
#
# Usage: fm-queue-snapshot.sh [--limit N] [--priority]   (default N=30)
#
# By default `rank` orders the full queued set by gate class first
# (dispatchable, blocked, captain, deferred-until, in that order - the same
# order the /queue skill renders its four sections in), then by project
# (repo, "-" last) as the secondary key within each gate class, then - for
# deferred rows only - by hold date ascending (soonest first), then by
# `created` descending (newest first) as the final tiebreak; `--limit` is
# applied after that full ordering, exactly as it was applied after the
# priority sort before this flag existed. Pass `--priority` to restore the
# prior default: sort the full queued set by descending `priority` instead
# (ties keep tasks-axi's own return order), ignoring gate class entirely.
# `gate` and `rank` are still emitted on every row either way; `--priority`
# only changes which order produces `rank`.
#
# Output (stable field order; the rows are RFC4180 CSV, so an embedded quote is
# doubled - "" - not backslash-escaped as tasks-axi's own TOON input is, and a
# newline, carriage return, or tab inside a value is written back as the literal
# two-character \n, \r, or \t - with any literal backslash doubled to \\ so those
# escapes stay unambiguous - so every item stays on exactly one LF-terminated
# line):
#   count: <n>
#   total_queued: <n>
#     -- present ONLY when --limit truncated the full queued set (count is
#     smaller than the total number of queued items tasks-axi returned), so a
#     capped listing is never mistaken for the whole queue; absent entirely
#     when nothing was truncated --
#   items[<n>]{rank,id,title,kind,repo,priority,blocked,blocked_by,held,hold_kind,hold_reason,hold_until,posture,autonomy,autonomy_reason,gate,created}:
#     <csv row>...
#     `created` is tasks-axi's own item-creation date (empty string if tasks-axi
#     reports none for that item) - carried through unmodified, never
#     reformatted or age-computed here; the caller derives age from it.
#     `gate` is a deterministic gate-class verdict for grouping the list -
#     "dispatchable", "blocked", "captain", or "deferred-until <date>" (using
#     the item's own `hold_until` verbatim) - derived, never guessed, from
#     this same row's `blocked`/`hold_until` fields and the `autonomy` verdict
#     computed just above: `blocked` when `blocked` is yes (a blocking chain
#     always wins, regardless of any hold); else `deferred-until <hold_until>`
#     when held with a `hold_until` date set; else `captain` when held with no
#     `hold_until` (an open-ended hold), OR when `autonomy` is
#     `captain-gated` OR `unclear` (an unresolved project is a captain
#     question, not a dispatchable one); else `dispatchable`.
#   hidden[<n>]{repo,count}:
#     <csv row>...
#     -- present ONLY when --limit truncated the full queued set (same
#     condition as total_queued above); one row per distinct repo (repo "-"
#     for items with no project recorded) among the items --limit cut, counted
#     from the SAME full queued set total_queued is drawn from (before the
#     limit, not after), sorted by descending count then repo name, so the
#     caller can print a "hidden: N by project" summary without re-deriving it
#     -- absent entirely when nothing was truncated --
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
#     produced no evidence for that harness (not installed/authenticated, this
#     script has no provider mapping for it, or the provider reported no
#     model-scoped and no account-wide effectiveAvailability entry) - never
#     guessed as yes or no from any other window. A lane with a model is bound
#     by whichever is lower of that model's own "model:<name>" scoped
#     availability and the account-wide number (every "all_models" and
#     "all_products" entry the provider publishes, whichever of them is
#     lowest), and the reason names that binding scope, so neither a
#     model-exhausted lane nor an exhausted account is ever reported
#     available on the other one's headroom. A "model:<name>" scope binds a
#     lane only when its token equals the lane's model exactly, or is one of
#     the vendor family short names (opus/sonnet/haiku/fable) appearing as a
#     whole segment of the lane's model, so "model:opus" bounds
#     "claude-opus-5". When more than one such scope binds a lane, the tightest
#     of them is the one reported, whatever order quota-axi listed them in. A scope naming any other distinct model
#     ("model:gpt-5-codex" against a "gpt-5" lane, or "model:gpt-5" against a
#     "gpt-5-codex" lane) never binds, and that lane reads the account-wide
#     number instead. This block never lists a lane firstmate's dispatch config does not
#     itself configure, so a harness with no configured rule (a retired
#     subscription, for example) never appears here.
#     When the dispatch config becomes unreadable between the validity check
#     and this read, the block reports
#     "hierarchy_lanes: unavailable (dispatch_config: unreadable)".
#   live_slots: <n>
#     count of dispatched worker slots currently tracked (spawned, not yet torn
#     down) in this FM_HOME - one per state/*.meta entry, except that
#     kind=secondmate records are excluded because a secondmate is persistent
#     infrastructure rather than dispatched backlog work and holds no dispatch
#     slot. This is not a live/dead endpoint check, which is a
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
  awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

LIMIT=30
SORT_MODE=gate
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
    --priority)
      SORT_MODE=priority
      shift
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

FIELDS="blocked,blocked_by,held,hold_kind,hold_reason,hold_until,priority,created"
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
FM_QUEUE_SORT_MODE="$SORT_MODE" \
FM_QUEUE_CFG="$CFG" \
FM_QUEUE_STATE_DIR="$FM_HOME/state" \
python3 - "$TMP_LIST" <<'PY'
import csv
import glob
import json
import os
import re
import subprocess
import sys

project_mode_bin = os.environ["FM_QUEUE_PROJECT_MODE_BIN"]
dispatch_status = os.environ["FM_QUEUE_DISPATCH_STATUS"]
limit = int(os.environ["FM_QUEUE_LIMIT"])
sort_mode = os.environ["FM_QUEUE_SORT_MODE"]
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
          "held", "hold_kind", "hold_reason", "hold_until", "created")

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


def inferred_project_for(item_id):
    try:
        out = subprocess.run(
            [project_mode_bin, "--infer-project-from-id", item_id],
            capture_output=True, text=True, check=False,
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except OSError:
        return ""


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


GATE_ORDER = {"dispatchable": 0, "blocked": 1, "captain": 2}


def gate_sort_key(gate):
    if gate in GATE_ORDER:
        return GATE_ORDER[gate]
    return 3  # deferred-until <date>


def deferred_date(gate):
    if gate.startswith("deferred-until "):
        return gate[len("deferred-until "):]
    return ""


# Derive posture/autonomy/gate for every queued item up front (not just the
# post-limit slice) so gate-class ordering can be applied to the full set
# before `--limit` cuts it; posture_for is repo-cached, so this costs one
# fm-project-mode.sh call per distinct project, not per item.
enriched = []
for r in rows:
    captain_kind = r["kind"] == "captain" or r["hold_kind"] == "captain"
    repo = r["repo"]
    has_repo = bool(repo) and repo != "-"
    inferred_reason = None
    if not has_repo:
        inferred = inferred_project_for(r["id"])
        if inferred:
            has_repo, inferred_reason = True, "project inferred from id prefix"
            posture = posture_for(inferred)
        else:
            posture = "n/a"
    else:
        posture = posture_for(repo)
    if captain_kind:
        autonomy, reason = "captain-gated", "captain kind or captain-kind hold"
    elif not has_repo:
        autonomy, reason = "unclear", "no project recorded on this item"
    else:
        yolo = posture.split()[-1] if posture else "off"
        if yolo == "off":
            autonomy, reason = "captain-gated", inferred_reason or "project registry posture has yolo off"
        else:
            autonomy, reason = "autonomous-eligible", inferred_reason or "project registry posture has yolo on"
    blocked_flag = r["blocked"] == "yes"
    held_flag = r["held"] == "yes"
    hold_until = r["hold_until"]
    if hold_until == "-":
        hold_until = ""
    if blocked_flag:
        gate = "blocked"
    elif held_flag and hold_until:
        gate = f"deferred-until {hold_until}"
    elif held_flag or autonomy in ("captain-gated", "unclear"):
        gate = "captain"
    else:
        gate = "dispatchable"
    enriched.append((r, repo, posture, autonomy, reason, gate))

if sort_mode == "priority":
    # Stable sort by descending priority; equal-priority items (including
    # "-", the lowest bucket) keep tasks-axi's own return order as the
    # tiebreak, since `enriched` is already in that order and Python's sort
    # is stable.
    sorted_enriched = sorted(
        enriched, key=lambda e: -priority_key(e[0]["priority"])
    )
else:
    # Default: gate class first (dispatchable, blocked, captain,
    # deferred-until, in that order), then project (repo, "-" last) as the
    # secondary key, then hold date ascending for deferred items, then
    # newest-first by `created` as the final tiebreak.
    # Two stable passes: sort by `created` descending first, then re-sort by
    # (gate, repo, hold date) - the stable sort preserves the
    # `created`-descending order within each equal group.
    sorted_enriched = sorted(enriched, key=lambda e: e[0]["created"], reverse=True)
    sorted_enriched = sorted(
        sorted_enriched,
        key=lambda e: (
            gate_sort_key(e[5]),
            (1, "") if e[1] in ("", "-") else (0, e[1]),
            deferred_date(e[5]),
        ),
    )

ranked_enriched = sorted_enriched[:limit]
hidden_rows_src = [e[0] for e in sorted_enriched[limit:]]

out_rows = []
for rank, (r, repo, posture, autonomy, reason, gate) in enumerate(
    ranked_enriched, start=1
):
    out_rows.append([
        rank, r["id"], r["title"], r["kind"], repo, r["priority"],
        r["blocked"], r["blocked_by"], r["held"], r["hold_kind"],
        r["hold_reason"], r["hold_until"], posture, autonomy, reason,
        gate, r["created"],
    ])

print(f"count: {len(out_rows)}")
if len(out_rows) < len(rows):
    print(f"total_queued: {len(rows)}")
if out_rows:
    cols = ("rank,id,title,kind,repo,priority,blocked,blocked_by,held,"
            "hold_kind,hold_reason,hold_until,posture,autonomy,autonomy_reason,"
            "gate,created")
    print(f"items[{len(out_rows)}]{{{cols}}}:")
    writer = csv.writer(sys.stdout, lineterminator="\n")
    for row in out_rows:
        cells = [one_line(str(v)) for v in row]
        writer.writerow(["  " + cells[0]] + cells[1:])

if len(out_rows) < len(rows):
    hidden_counts = {}
    for r in hidden_rows_src:
        repo_key = r["repo"] or "-"
        hidden_counts[repo_key] = hidden_counts.get(repo_key, 0) + 1
    hidden_rows = sorted(hidden_counts.items(), key=lambda kv: (-kv[1], kv[0]))
    print(f"hidden[{len(hidden_rows)}]{{repo,count}}:")
    writer = csv.writer(sys.stdout, lineterminator="\n")
    for repo_key, cnt in hidden_rows:
        writer.writerow(["  " + one_line(repo_key), cnt])

print(f"dispatch_config: {dispatch_status}")

# --- hierarchy lanes: config/crew-dispatch.json rules/default enriched with
# one bounded, aggregate quota-axi read (never per queued item). -----------

HARNESS_TO_PROVIDER = {
    "claude": "claude",
    "codex": "codex",
    "cursor": "cursor",
    "grok": "grok",
    "kimi": "kimi",
}


QUOTA_TIMEOUT_SECONDS = 10


def profiles_of(value):
    if isinstance(value, list):
        return [v for v in value if isinstance(v, dict)]
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
        parsed = json.loads(proc.stdout)
    except (ValueError, TypeError):
        return None
    return parsed if isinstance(parsed, dict) else None


ACCOUNT_WIDE_SCOPES = ("all_models", "all_products")


def model_scope_token(scope):
    if not isinstance(scope, str) or not scope.startswith("model:"):
        return ""
    return scope.split(":", 1)[1].strip().lower()


FAMILY_ALIAS_SCOPES = frozenset({"opus", "sonnet", "haiku", "fable"})


def scope_segments(text):
    return [seg for seg in re.split(r"[^a-z0-9]+", text) if seg]


def scope_names_model(token, name):
    if token not in FAMILY_ALIAS_SCOPES:
        return False
    return token in scope_segments(name)


def pick_model_scoped(availability, model):
    name = model.strip().lower()
    if not name:
        return None
    matches = []
    for entry in availability:
        token = model_scope_token(entry.get("scope"))
        if not token:
            continue
        if token == name or scope_names_model(token, name):
            matches.append(entry)
    return matches or None


def availability_for(harness, model, quota_data):
    provider_name = HARNESS_TO_PROVIDER.get(harness)
    if provider_name is None:
        return "unknown", "no quota-axi provider mapping for this worker runtime"
    if quota_data is None:
        return "unknown", "quota-axi produced no evidence"
    providers = quota_data.get("providers")
    if not isinstance(providers, list):
        providers = []
    provider = next(
        (
            p for p in providers
            if isinstance(p, dict) and p.get("provider") == provider_name
        ),
        None,
    )
    if provider is None:
        return "unknown", f"no live quota data for {provider_name}"
    semantics = provider.get("quotaSemantics")
    entries = semantics.get("effectiveAvailability") if isinstance(semantics, dict) else None
    availability = [a for a in entries if isinstance(a, dict)] if isinstance(entries, list) else []
    candidates = []
    scoped = pick_model_scoped(availability, model) if model else None
    if scoped:
        candidates.extend(scoped)
    candidates.extend(
        a for a in availability if a.get("scope") in ACCOUNT_WIDE_SCOPES
    )
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
    return "unknown", f"no model or account-wide quota evidence for {provider_name}"


if dispatch_status != "present":
    print(f"hierarchy_lanes: unavailable (dispatch_config: {dispatch_status})")
else:
    try:
        with open(cfg_path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except (OSError, ValueError):
        cfg = None
    if not isinstance(cfg, dict):
        cfg = None
    lanes = []
    rules = (cfg or {}).get("rules")
    for rule in rules if isinstance(rules, list) else []:
        if not isinstance(rule, dict):
            continue
        when = rule.get("when") or ""
        for profile in profiles_of(rule.get("use")):
            lanes.append(("rule", when, profile))
    for profile in profiles_of((cfg or {}).get("default")):
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
    elif cfg is None:
        print("hierarchy_lanes: unavailable (dispatch_config: unreadable)")
    else:
        print("hierarchy_lanes: unavailable (config defines no dispatch profiles)")

def meta_kind(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                key, sep, value = line.partition("=")
                if sep and key.strip() == "kind":
                    return value.strip()
    except OSError:
        return ""
    return ""


live_slots = sum(
    1 for meta in glob.glob(os.path.join(state_dir, "*.meta"))
    if meta_kind(meta) != "secondmate"
)
print(f"live_slots: {live_slots}")
PY
