#!/usr/bin/env bash
# fm-backlog-routing.sh - the single owner of the durable PC02/medium/senior
# routing registry the /autonomous pass's refill step joins onto a fresh
# bin/fm-queue-snapshot.sh read.
#
# Why: fm-queue-snapshot.sh deliberately does not resolve purpose/tier/model
# (its own header says so) and its default ordering is gate, project, then
# newest-first - so a refill loop can find eligible rows but cannot
# deterministically identify the low-risk PC02 roster or prevent old work
# from starving. This script persists ONE routing judgment per item so that
# classification work is done once, not re-derived at every pass. It is not
# a second gate/autonomy owner: fm-queue-snapshot.sh remains authoritative
# for gate/autonomy, and a routing row can only narrow what fm-pc02-fair-order.sh
# offers, never widen eligibility past what the snapshot already allows.
# See data/backlog-triage-durable-plan/report.md (captain's ruling
# 2026-09-08) for the full design this implements.
#
# Storage: data/backlog-routing.tsv, one line per classified item -
#   <id>\t<class>\t<sidecar>\t<risk>\t<purpose>\t<classified_at>\t<source_digest>
# class is pc02|medium|senior; sidecar is "codex" or empty; risk and purpose
# are short free-text tokens (no tabs/newlines - stripped if present);
# classified_at is a UTC ISO8601 timestamp; source_digest is a sha256 of the
# item's title, body, kind, and repo, joined with \x1f, so an edited item's
# stale classification is detected rather than silently trusted (see `get`
# below). A missing row is simply unclassified - never guessed here.
#
# Ledger: every `set`, `escalate`, and `gc` append one line to
# data/routing-ledger.tsv: <epoch>\t<event>\t<id>\t<class>, where event is
# classified|escalated|closed. bin/fm-routing-ledger-metrics.sh is the single
# reader of that file; this script only appends.
#
# Locking: both sidecars are rewritten whole under a plain mkdir-lockdir
# mutex, the same whole-file-rewrite pattern bin/fm-captain-hold.sh's
# mark_set/mark_clear use for data/task-marks.tsv, so a concurrent writer
# never bases a rewrite on a version this one is replacing.
#
# Usage:
#   fm-backlog-routing.sh set <id> <pc02|medium|senior> [--sidecar codex]
#     [--risk <text>] [--purpose <text>]
#     Computes the current digest from tasks-axi and writes/overwrites the
#     row, stamping classified_at to now. Appends a "classified" ledger line.
#   fm-backlog-routing.sh escalate <id> <medium|senior> --reason <text>
#     Tier-escalation seam: moves a row to a higher tier after a PC02
#     failure, preserving sidecar, recomputing the digest, and appending an
#     "escalated" ledger line whose reason names the trigger. Refuses to
#     escalate an id with no existing row (escalation edits a judgment,
#     it does not invent one) and refuses a "downgrade" back toward pc02
#     (this seam only ever moves work up, per the report's own
#     never-loop-back-silently rule).
#   fm-backlog-routing.sh get <id>
#     Prints one line: "absent", or "stale: <class>" when a row exists but
#     its digest no longer matches the item's current title/body/kind/repo,
#     or "present: <class> <sidecar> <risk> <purpose> <classified_at>"
#     (sidecar/risk/purpose print as "-" when empty). Exit 0 for
#     present/stale, exit 1 for absent, exit 2 on a usage/read error.
#   fm-backlog-routing.sh list [--class <pc02|medium|senior>]
#     Prints every row (optionally filtered by class) as TAB-separated
#     id/class/sidecar/risk/purpose/classified_at/source_digest, one per
#     line, in file order. Never validates digests (callers that need
#     freshness use `get` per id, or fm-pc02-fair-order.sh which does it
#     for the whole pc02 class in one pass).
#   fm-backlog-routing.sh gc <id>
#     Removes the row (used once an item closes, so a reused id can never
#     inherit a stale classification) and appends a "closed" ledger line
#     carrying the class the row had before removal. A no-op (exit 0) when
#     no row exists.
#
# Exit codes: 0 success, 1 = "absent"/"occupied"-shaped negative answer
# (see per-command notes above), 2 = usage error, missing dependency, or
# unreadable registry.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ROUTING="$DATA/backlog-routing.tsv"
LEDGER="$DATA/routing-ledger.tsv"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

fm_routing_log() { echo "fm-backlog-routing: $*" >&2; }

VALID_CLASSES="pc02 medium senior"
class_valid() {
  case " $VALID_CLASSES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

class_rank() {
  case "$1" in
    pc02) echo 0 ;;
    medium) echo 1 ;;
    senior) echo 2 ;;
    *) echo -1 ;;
  esac
}

sanitize_field() {
  # Strip tabs/newlines so a free-text field can never corrupt the TSV shape.
  printf '%s' "$1" | tr '\t\n\r' '   '
}

# fm-captain-hold.sh's mark_set/mark_clear do not expose a reusable
# acquire/release pair (they are file-local), so this script uses the same
# simple mkdir-lockdir pattern directly: atomic, portable, and self-cleaning
# via the trap each command registers around its own write.
acquire_lockdir() {  # <lockdir>
  local lockdir=$1 tries=0
  mkdir -p "$(dirname "$lockdir")"
  while ! mkdir "$lockdir" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 50 ]; then
      fm_routing_log "could not acquire lock $lockdir after ${tries} tries"
      return 1
    fi
    sleep 0.1
  done
  return 0
}

release_lockdir() {  # <lockdir>
  rmdir "$1" 2>/dev/null || true
}

require_tasks_axi() {
  command -v tasks-axi >/dev/null 2>&1 || {
    fm_routing_log "tasks-axi not found on PATH"
    exit 2
  }
}

# Prints "<title>\x1f<body>\x1f<kind>\x1f<repo>" for id, or fails (exit 1)
# when the item cannot be found - a digest can never be computed from a
# partial read. Reads `tasks-axi show <id> --full` rather than
# `list --fields body`, because `list` truncates title and body at ~150
# characters: a digest built from a truncated prefix cannot detect an edit
# made past the cut, which is exactly the staleness `get` exists to catch.
# `show --full` emits one "  key: value" line per field with newlines/tabs
# escaped inside the quoted value, so each field stays on a single line and
# the raw serialized value is a faithful, injective image of the full text.
item_fields() {  # <id>
  local id=$1 out
  out=$(cd "$FM_HOME" && tasks-axi show "$id" --full 2>/dev/null | \
    awk '
      /^error:/ || /^code: NOT_FOUND/ { notfound = 1 }
      /^  [a-z_]+: / {
        line = $0
        sub(/^  /, "", line)
        key = line
        sub(/:.*$/, "", key)
        val = line
        sub(/^[a-z_]+: /, "", val)
        if (!(key in f)) { f[key] = val }
      }
      END {
        if (notfound || !("id" in f)) { exit 1 }
        printf "%s\x1f%s\x1f%s\x1f%s\n", f["title"], f["body"], f["kind"], f["repo"]
      }
    ')
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

digest_of_fields() {  # <fields-string>
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    fm_routing_log "no sha256sum/shasum on PATH"
    exit 2
  fi
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch_now() { date -u +%s; }

ledger_append() {  # <event> <id> <class> [<reason>]
  local event=$1 id=$2 class=$3 reason=${4:-} lockdir="$DATA/.routing-ledger.lock"
  mkdir -p "$DATA"
  acquire_lockdir "$lockdir" || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$(epoch_now)" "$event" "$id" "$class" "$(sanitize_field "$reason")" >> "$LEDGER"
  release_lockdir "$lockdir"
}

# Rewrites $ROUTING with $id's line replaced by $new_line (or removed when
# new_line is empty), preserving every other row's order.
# A registry that exists but cannot be read is a refusal, never an empty
# registry: every caller below would otherwise answer as if the classification
# work simply did not exist, and rewrite the file from that false premise.
require_readable_registry() {
  if [ -e "$ROUTING" ] && [ ! -r "$ROUTING" ]; then
    fm_routing_log "routing registry exists but is not readable: $ROUTING"
    return 1
  fi
  return 0
}

routing_rewrite() {  # <id> <new_line-or-empty>
  local id=$1 new_line=$2 tmp
  require_readable_registry || return 1
  tmp="$ROUTING.tmp.$$"
  mkdir -p "$DATA"
  if [ -f "$ROUTING" ]; then
    if ! awk -F'\t' -v i="$id" '$1 != i { print }' "$ROUTING" > "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
  else
    : > "$tmp"
  fi
  if [ -n "$new_line" ]; then
    printf '%s\n' "$new_line" >> "$tmp"
  fi
  mv "$tmp" "$ROUTING" || { rm -f "$tmp"; return 1; }
}

# Exit 0 = row printed, 1 = no such row, 2 = the registry could not be read.
routing_row_for() {  # <id>
  require_readable_registry || return 2
  [ -f "$ROUTING" ] || return 1
  awk -F'\t' -v i="$1" '$1 == i { print; found = 1 } END { exit found ? 0 : 1 }' "$ROUTING" || return 1
}

cmd_set() {
  local id=${1:-} class=${2:-} sidecar="" risk="" purpose=""
  [ -n "$id" ] && [ -n "$class" ] || { fm_routing_log "set requires <id> <class>"; exit 2; }
  shift 2 || true
  class_valid "$class" || { fm_routing_log "invalid class: $class (want pc02|medium|senior)"; exit 2; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --sidecar) sidecar=${2:?--sidecar needs a value}; shift 2 ;;
      --risk) risk=${2:?--risk needs a value}; shift 2 ;;
      --purpose) purpose=${2:?--purpose needs a value}; shift 2 ;;
      *) fm_routing_log "unknown argument: $1"; exit 2 ;;
    esac
  done
  if [ -n "$sidecar" ] && [ "$sidecar" != codex ]; then
    fm_routing_log "--sidecar only accepts 'codex', got: $sidecar"
    exit 2
  fi
  require_tasks_axi
  local fields digest ts lockdir="$DATA/.backlog-routing.lock"
  fields=$(item_fields "$id") || { fm_routing_log "no such queued/known item: $id"; exit 2; }
  digest=$(digest_of_fields "$fields")
  ts=$(utc_now)
  acquire_lockdir "$lockdir" || exit 2
  if ! routing_rewrite "$id" "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$id" "$class" "$sidecar" "$(sanitize_field "$risk")" "$(sanitize_field "$purpose")" "$ts" "$digest")"; then
    release_lockdir "$lockdir"
    fm_routing_log "could not write the routing row for $id"
    exit 2
  fi
  release_lockdir "$lockdir"
  ledger_append classified "$id" "$class" || {
    fm_routing_log "row for $id written but the classified ledger line could not be appended"
    exit 2
  }
}

cmd_escalate() {
  local id=${1:-} class=${2:-} reason=""
  [ -n "$id" ] && [ -n "$class" ] || { fm_routing_log "escalate requires <id> <medium|senior>"; exit 2; }
  shift 2 || true
  case "$class" in
    medium|senior) ;;
    *) fm_routing_log "escalate only accepts medium|senior, got: $class"; exit 2 ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) reason=${2:?--reason needs a value}; shift 2 ;;
      *) fm_routing_log "unknown argument: $1"; exit 2 ;;
    esac
  done
  [ -n "$reason" ] || { fm_routing_log "escalate requires --reason"; exit 2; }
  local existing sidecar rc
  existing=$(routing_row_for "$id"); rc=$?
  [ "$rc" -ne 2 ] || exit 2
  [ "$rc" -eq 0 ] || { fm_routing_log "cannot escalate $id: no existing routing row"; exit 1; }
  local old_class
  old_class=$(printf '%s' "$existing" | cut -f2)
  sidecar=$(printf '%s' "$existing" | cut -f3)
  if [ "$(class_rank "$class")" -le "$(class_rank "$old_class")" ]; then
    fm_routing_log "escalate only moves up: $id is already $old_class, refusing $class"
    exit 2
  fi
  require_tasks_axi
  local fields digest ts lockdir="$DATA/.backlog-routing.lock"
  fields=$(item_fields "$id") || { fm_routing_log "no such queued/known item: $id"; exit 2; }
  digest=$(digest_of_fields "$fields")
  ts=$(utc_now)
  acquire_lockdir "$lockdir" || exit 2
  if ! routing_rewrite "$id" "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$id" "$class" "$sidecar" "$(printf '%s' "$existing" | cut -f4)" "$(printf '%s' "$existing" | cut -f5)" "$ts" "$digest")"; then
    release_lockdir "$lockdir"
    fm_routing_log "could not write the escalated routing row for $id"
    exit 2
  fi
  release_lockdir "$lockdir"
  ledger_append escalated "$id" "$class" "$reason" || {
    fm_routing_log "row for $id escalated but the escalated ledger line could not be appended"
    exit 2
  }
}

cmd_get() {
  local id=${1:-}
  [ -n "$id" ] || { fm_routing_log "get requires <id>"; exit 2; }
  local row rc
  row=$(routing_row_for "$id"); rc=$?
  [ "$rc" -ne 2 ] || exit 2
  if [ "$rc" -ne 0 ]; then
    echo absent
    exit 1
  fi
  local rclass rsidecar rrisk rpurpose rts rdigest
  rclass=$(printf '%s' "$row" | cut -f2)
  rsidecar=$(printf '%s' "$row" | cut -f3)
  rrisk=$(printf '%s' "$row" | cut -f4)
  rpurpose=$(printf '%s' "$row" | cut -f5)
  rts=$(printf '%s' "$row" | cut -f6)
  rdigest=$(printf '%s' "$row" | cut -f7)
  require_tasks_axi
  local fields digest
  if ! fields=$(item_fields "$id"); then
    echo "stale: $rclass"
    exit 0
  fi
  digest=$(digest_of_fields "$fields")
  if [ "$digest" != "$rdigest" ]; then
    echo "stale: $rclass"
    exit 0
  fi
  printf 'present: %s %s %s %s %s\n' \
    "$rclass" "${rsidecar:--}" "${rrisk:--}" "${rpurpose:--}" "$rts"
  exit 0
}

cmd_list() {
  local want_class=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --class) want_class=${2:?--class needs a value}; shift 2 ;;
      *) fm_routing_log "unknown argument: $1"; exit 2 ;;
    esac
  done
  require_readable_registry || exit 2
  [ -f "$ROUTING" ] || exit 0
  if [ -n "$want_class" ]; then
    awk -F'\t' -v c="$want_class" '$2 == c { print }' "$ROUTING"
  else
    cat "$ROUTING"
  fi
}

cmd_gc() {
  local id=${1:-}
  [ -n "$id" ] || { fm_routing_log "gc requires <id>"; exit 2; }
  local row lockdir="$DATA/.backlog-routing.lock" class rc
  # Everything below runs under the routing lock, so the row's existence
  # check, its archive, and its removal are one step no concurrent pass can
  # interleave with. One window remains: if the archive succeeds and the
  # rewrite then fails (ENOSPC, a data dir gone read-only), the row survives
  # with its "closed" line already written, and a retried gc archives it a
  # second time - so the diagnostic below names that state explicitly rather
  # than carrying retry/dedupe bookkeeping for it.
  acquire_lockdir "$lockdir" || exit 2
  row=$(routing_row_for "$id"); rc=$?
  if [ "$rc" -ne 0 ]; then
    release_lockdir "$lockdir"
    [ "$rc" -ne 2 ] || exit 2
    exit 0
  fi
  class=$(printf '%s' "$row" | cut -f2)
  if ! ledger_append closed "$id" "$class"; then
    release_lockdir "$lockdir"
    fm_routing_log "refusing to gc $id: could not append its closed ledger line"
    exit 2
  fi
  if ! routing_rewrite "$id" ""; then
    release_lockdir "$lockdir"
    fm_routing_log "gc $id: archived to the ledger but the registry rewrite failed"
    exit 2
  fi
  release_lockdir "$lockdir"
}

cmd_seed_from_report() {
  local report=${1:-}
  [ -n "$report" ] && [ -f "$report" ] || { fm_routing_log "seed-from-report requires an existing report path"; exit 2; }
  require_tasks_axi
  local section="" seeded=0 skipped=0
  while IFS= read -r line; do
    case "$line" in
      '#### PC02-first roster'*) section=pc02; continue ;;
      '#### Medium / standard cloud roster'*) section=medium; continue ;;
      '#### Senior roster'*) section=senior; continue ;;
      '#### '*|'### '*|'## '*) section=""; continue ;;
    esac
    [ -n "$section" ] || continue
    case "$line" in
      '| `'*)
        local id
        id=$(printf '%s' "$line" | sed -n 's/^| `\([^`]*\)`.*/\1/p')
        [ -n "$id" ] || continue
        # cmd_get/cmd_set exit the process on their own error paths (they
        # are also this script's top-level CLI entry points), so each call
        # here must run in a subshell or its exit would abort this whole
        # seed loop instead of just skipping one row.
        if ( cmd_get "$id" ) >/dev/null 2>&1; then
          skipped=$((skipped + 1))
          continue
        fi
        if ( cmd_set "$id" "$section" ) >/dev/null 2>&1; then
          seeded=$((seeded + 1))
        else
          skipped=$((skipped + 1))
        fi
        ;;
    esac
  done < "$report"
  echo "seeded: $seeded skipped: $skipped"
}

CMD="${1:-}"
shift || true
case "$CMD" in
  set) cmd_set "$@" ;;
  escalate) cmd_escalate "$@" ;;
  get) cmd_get "$@" ;;
  list) cmd_list "$@" ;;
  gc) cmd_gc "$@" ;;
  seed-from-report) cmd_seed_from_report "$@" ;;
  "")
    fm_routing_log "missing command (set|escalate|get|list|gc|seed-from-report)"
    exit 2
    ;;
  *)
    fm_routing_log "unknown command: $CMD"
    exit 2
    ;;
esac
