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
# Tier/model/effort resolution is deliberately OUT of scope: matching an
# item's description against config/crew-dispatch.json's natural-language
# `when` rules is judgment, the same judgment AGENTS.md section 4 gives to
# firstmate at real dispatch time, and a profile array's concrete pick
# additionally needs live quota-axi evidence this script must not spend on a
# listing. This script only reports whether config/crew-dispatch.json is
# present/absent/invalid/unverified so the caller knows whether tier matching is
# even possible; the caller (the /queue skill) reads the file itself and does
# the matching. "present" means the file passes the shared crew-dispatch
# validity contract in bin/fm-crew-dispatch-lib.sh - the same verdict
# bin/fm-bootstrap.sh reports as CREW_DISPATCH - not merely that it parses as
# JSON, so the skill never publishes tiers from a config real dispatch would
# refuse. "unverified" means that contract could not be evaluated here because
# jq is unavailable; the caller must treat it as untrustworthy for tiers rather
# than guessing.
#
# This script is READ-ONLY: it runs no tasks-axi mutation, writes no file,
# and never spends quota or network.
#
# Usage: fm-queue-snapshot.sh [--limit N]   (default N=30)
#
# Output (stable field order; the rows are RFC4180 CSV, so an embedded quote is
# doubled - "" - not backslash-escaped as tasks-axi's own TOON input is, and a
# newline, carriage return, or tab inside a value is written back as the literal
# two-character \n, \r, or \t so every item stays on exactly one line):
#   count: <n>
#   items[<n>]{id,title,kind,repo,priority,blocked,blocked_by,held,hold_kind,hold_reason,hold_until,posture,autonomy,autonomy_reason}:
#     <csv row>...
#   dispatch_config: absent|present|invalid|unverified
#
# Fails loudly (exit 1) when tasks-axi is missing or its list call errors,
# rather than reporting an empty queue that might just be a broken lookup.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//'
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

TMP_LIST="$(mktemp)"
TMP_ERR="$(mktemp)"
trap 'rm -f "$TMP_LIST" "$TMP_ERR"' EXIT

FIELDS="blocked,blocked_by,held,hold_kind,hold_reason,hold_until,priority"
if ! (cd "$FM_HOME" && tasks-axi list --state queued --fields "$FIELDS" --limit "$LIMIT") \
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

FM_QUEUE_PROJECT_MODE_BIN="$PROJECT_MODE_BIN" FM_QUEUE_DISPATCH_STATUS="$dispatch_status" python3 - "$TMP_LIST" <<'PY'
import csv
import os
import subprocess
import sys

project_mode_bin = os.environ["FM_QUEUE_PROJECT_MODE_BIN"]
dispatch_status = os.environ["FM_QUEUE_DISPATCH_STATUS"]

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


out_rows = []
for r in rows:
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
        r["id"], r["title"], r["kind"], repo, r["priority"],
        r["blocked"], r["blocked_by"], r["held"], r["hold_kind"],
        r["hold_reason"], r["hold_until"], posture, autonomy, reason,
    ])

print(f"count: {len(out_rows)}")
if out_rows:
    cols = ("id,title,kind,repo,priority,blocked,blocked_by,held,"
            "hold_kind,hold_reason,hold_until,posture,autonomy,autonomy_reason")
    print(f"items[{len(out_rows)}]{{{cols}}}:")
    writer = csv.writer(sys.stdout)
    for row in out_rows:
        cells = [one_line(str(v)) for v in row]
        writer.writerow(["  " + cells[0]] + cells[1:])
print(f"dispatch_config: {dispatch_status}")
PY
