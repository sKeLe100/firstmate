#!/usr/bin/env bash
# fm-pc02-fair-order.sh - fair dispatch order for the PC02-classified roster,
# the ordering half of the durable refill design in
# data/backlog-triage-durable-plan/report.md (captain's ruling 2026-09-08).
#
# Why: bin/fm-queue-snapshot.sh's default order is gate class, then project,
# then newest-first. That starves old items and gives no way to harvest
# genuinely tiny work before a long one, or to guarantee an unblocking item
# runs first. This script takes the SAME snapshot bin/fm-queue-snapshot.sh
# produces, narrows it to rows classified `pc02` (and not stale) in
# data/backlog-routing.tsv via bin/fm-backlog-routing.sh, and reorders only
# that subset. It never widens what the snapshot already allows: any row
# whose `gate` is not `dispatchable` is excluded before ordering even runs,
# so routing can narrow eligibility, never widen it (report failure-mode
# "Gate bypass").
#
# Ordering (report step 5, applied as three sequential blocks; each block is
# internally ordered by the stable tiebreak below):
#   A. Dependency-cleared: rows whose id appears in another QUEUED row's
#      blocked_by (dispatching them clears a dependency for other work).
#   B. Priority-carrying: remaining rows with a numeric tasks-axi priority
#      set, ordered by priority descending.
#   C. Everything else: a repeating 3-shortest/1-oldest rotation. "Shortest"
#      is approximated by the item's tasks-axi title-plus-body length in
#      characters (ascending) - a deterministic, bounded proxy for
#      "small/bounded work" documented here because no real cycle-time
#      series exists yet (report "Resource accounting"); title is included
#      because `tasks-axi add` leaves body empty unless explicitly given
#      one, and a bare title still carries real signal. "Oldest" is
#      `created` ascending. The rotation
#      always picks from what remains, so a short pool degrades gracefully to
#      an all-oldest tail once the short candidates run out.
# Stable tiebreak throughout: `created` ascending, then `id`.
#
# Usage: fm-pc02-fair-order.sh [--limit N]
#   --limit N   passed through to bin/fm-queue-snapshot.sh (default 500, wide
#               enough that a PC02 candidate near the back of a long queue is
#               never dropped from view before ordering runs).
#
# Output: one PC02-eligible-and-classified id per line, in dispatch order,
# to stdout. Empty output (exit 0) when nothing qualifies. Exit 2 on a
# usage or read error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

LIMIT=500
while [ $# -gt 0 ]; do
  case "$1" in
    --limit)
      LIMIT="${2:?--limit needs a value}"
      shift 2
      ;;
    *)
      echo "fm-pc02-fair-order: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

ROUTING_BIN="$SCRIPT_DIR/fm-backlog-routing.sh"
SNAPSHOT_BIN="$SCRIPT_DIR/fm-queue-snapshot.sh"
TASKS_AXI_BIN="$SCRIPT_DIR/fm-tasks-axi.sh"

SNAPSHOT_OUT="$(mktemp "${TMPDIR:-/tmp}/fm-pc02-fair-order-snap.XXXXXX")"
BODY_LENGTHS="$(mktemp "${TMPDIR:-/tmp}/fm-pc02-fair-order-body.XXXXXX")"
trap 'rm -f "$SNAPSHOT_OUT" "$BODY_LENGTHS"' EXIT

if ! FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SNAPSHOT_BIN" --limit "$LIMIT" > "$SNAPSHOT_OUT"; then
  echo "fm-pc02-fair-order: fm-queue-snapshot.sh failed" >&2
  exit 2
fi

if ! command -v tasks-axi >/dev/null 2>&1; then
  echo "fm-pc02-fair-order: tasks-axi not found on PATH" >&2
  exit 2
fi

# One bounded title/body-length read for the whole queued set (never per
# candidate), matching bin/fm-queue-snapshot.sh's own single-call ethos.
# Digest freshness is a separate, per-candidate single-item read owned by
# fm-backlog-routing.sh's `get`, because a truncated list field cannot carry
# a trustworthy digest.
# Routed through fm-tasks-axi.sh, the single owner of tasks-axi addressing,
# rather than a bare `cd "$FM_HOME" && tasks-axi`.
if ! "$TASKS_AXI_BIN" list --state queued --fields body > "$BODY_LENGTHS" 2>/dev/null; then
  echo "fm-pc02-fair-order: tasks-axi list --fields body failed" >&2
  exit 2
fi

# Ask fm-backlog-routing.sh for the live pc02 roster (id + digest state);
# `list --class pc02` is a raw dump (no freshness check), so this script
# validates freshness itself via `get` per candidate below, but first uses
# `list` only to avoid calling `get` for ids the registry does not carry at
# all (cheap prefilter, not a correctness shortcut).
if ! PC02_ROWS="$("$ROUTING_BIN" list --class pc02)"; then
  echo "fm-pc02-fair-order: fm-backlog-routing.sh list --class pc02 failed; refusing to report an empty PC02 roster" >&2
  exit 2
fi
PC02_IDS="$(printf '%s\n' "$PC02_ROWS" | awk -F'\t' 'NF { print $1 }')"

FRESH_IDS=""
while IFS= read -r cand_id; do
  [ -n "$cand_id" ] || continue
  out="$("$ROUTING_BIN" get "$cand_id" 2>/dev/null)"; rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "fm-pc02-fair-order: fm-backlog-routing.sh get $cand_id failed (exit $rc)" >&2
    exit 2
  fi
  case "$out" in
    present:*) FRESH_IDS="$FRESH_IDS$cand_id"$'\n' ;;
  esac
done <<< "$PC02_IDS"

FM_FAIR_ORDER_FRESH_IDS="$FRESH_IDS" \
python3 - "$SNAPSHOT_OUT" "$BODY_LENGTHS" <<'PY'
import csv
import os
import re
import sys

fresh_ids = set(x for x in os.environ.get("FM_FAIR_ORDER_FRESH_IDS", "").splitlines() if x)

TOON_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"'}


def unescape(value):
    out = []
    i = 0
    while i < len(value):
        ch = value[i]
        if ch == "\\" and i + 1 < len(value):
            out.append(TOON_ESCAPES.get(value[i + 1], value[i + 1]))
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


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


# --- parse fm-queue-snapshot.sh's CSV items[] block ------------------------

snap_path = sys.argv[1]
items = []
columns = None
in_block = False
with open(snap_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if line.startswith("items["):
            header = line[line.index("{") + 1:line.rindex("}")]
            columns = [c.strip() for c in header.split(",")]
            in_block = True
            continue
        if in_block and not line.startswith("  "):
            in_block = False
            continue
        if not in_block or columns is None:
            continue
        row = next(csv.reader([line.strip()]))
        if len(row) < len(columns):
            continue
        items.append({name: unescape(row[i]) for i, name in enumerate(columns)})

queued_ids = {r["id"] for r in items}

# --- parse tasks-axi list --fields body for the title+body length proxy ----
#
# `tasks-axi list` truncates title and body at ~150 characters and appends
# "... (truncated, <N> chars total - use show <id> --full ...)". Measuring
# the truncated string would score every long item as the same ~150-230
# characters, collapsing the "shortest" rotation into the created/id
# tiebreak; the marker's own N is the real length, so use it when present.
TRUNCATED_RE = re.compile(r"\(truncated, (\d+) chars total")


def true_len(value):
    match = TRUNCATED_RE.search(value)
    if match:
        return int(match.group(1))
    return len(value)


body_len = {}
body_path = sys.argv[2]
columns2 = None
in_block2 = False
with open(body_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if line.startswith("tasks["):
            header = line[line.index("{") + 1:line.rindex("}")] if "{" in line and "}" in line else ""
            columns2 = [c.strip() for c in header.split(",") if c.strip()]
            in_block2 = True
            continue
        if line.startswith("help["):
            in_block2 = False
            continue
        if not in_block2 or not line.startswith("  ") or columns2 is None:
            continue
        fields = split_toon_row(line.strip())
        if len(fields) < len(columns2):
            continue
        row = {name: fields[i] for i, name in enumerate(columns2)}
        if "id" in row and "body" in row:
            body_len[row["id"]] = true_len(row.get("title", "")) + true_len(row["body"])

# --- filter: dispatchable gate + fresh pc02 routing classification --------

candidates = [r for r in items if r.get("gate") == "dispatchable" and r["id"] in fresh_ids]

# Reverse blocked_by index over the FULL queued set (any state the snapshot
# returned, not just candidates), so a dependency-cleared verdict reflects
# every queued item that names this id as a blocker.
unblocks = set()
for r in items:
    if r.get("blocked") != "yes":
        continue
    for dep in (r.get("blocked_by") or "").split(","):
        dep = dep.strip()
        if dep:
            unblocks.add(dep)


def priority_key(value):
    return int(value) if value.isdigit() else None


def tiebreak(r):
    return (r.get("created", ""), r["id"])


group_a = sorted([r for r in candidates if r["id"] in unblocks], key=tiebreak)
rest = [r for r in candidates if r["id"] not in unblocks]

group_b = sorted(
    [r for r in rest if priority_key(r["priority"]) is not None],
    key=lambda r: (-priority_key(r["priority"]), tiebreak(r)),
)
group_b_ids = {r["id"] for r in group_b}
group_c_pool = [r for r in rest if r["id"] not in group_b_ids]

# Rotation: 3 shortest (by body length ascending, tiebreak created/id), then
# 1 oldest (created ascending), repeating until the pool is exhausted.
by_short = sorted(group_c_pool, key=lambda r: (body_len.get(r["id"], 0), tiebreak(r)))
by_old = sorted(group_c_pool, key=tiebreak)
used = set()
group_c = []
si = oi = 0
while len(group_c) < len(group_c_pool):
    taken_this_round = 0
    while taken_this_round < 3 and si < len(by_short):
        cand = by_short[si]
        si += 1
        if cand["id"] in used:
            continue
        used.add(cand["id"])
        group_c.append(cand)
        taken_this_round += 1
    if len(group_c) >= len(group_c_pool):
        break
    while oi < len(by_old):
        cand = by_old[oi]
        oi += 1
        if cand["id"] in used:
            continue
        used.add(cand["id"])
        group_c.append(cand)
        break

for r in group_a + group_b + group_c:
    print(r["id"])
PY
