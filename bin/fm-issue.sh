#!/usr/bin/env bash
# fm-issue.sh - the small issue layer tasks-axi does not carry.
#
# The backlog row itself is owned by tasks-axi and is only ever read or written
# through bin/fm-tasks-axi.sh. This command adds the few issue-database links
# and history tasks-axi 0.2.6 has no field for:
#   - one parent per item, with done/total child progress on the parent
#   - `related` (undirected) and `discovered-from` (directed) links
#   - an append-only, typed per-item log: done, failed, followup, question, note
#   - one bounded `show` lookup so a worker given only an id has the item, its
#     parent, open children, blockers, links, and recent log in one read
#   - a short `prime` for an agent that has never used the layer
#
# Everything beyond the row lives in ONE sidecar under the home data directory,
# data/issue-index.tsv, with tab-separated records:
#   link	<parent|related|discovered-from>	<a>	<b>	<utc>
#   unlink	<parent|related|discovered-from>	<a>	<b>	<utc>
#   log	<entry-type>	<id>	-	<utc>	<single-line text>
# Every record is appended under data/.issue-index.lock, so several writers
# cannot lose each other's writes and the log stays append-only. Tombstones
# (`unlink`) are also append-only; the sidecar is never rewritten. Readers
# tolerate a partial last line and a missing sidecar.
#
# The sidecar is addressed exactly as bin/fm-tasks-axi.sh addresses the backlog:
# FM_DATA_OVERRIDE, else $FM_HOME/data, else the code root's data/.
#
# Captain questions are not answered here. `log <id> question "text"` records the
# question and then places the item under a captain hold through
# bin/fm-captain-hold.sh, so the fleet keeps one answer channel. Rulings and
# memories stay in their existing owners (data/captain.md, data/learnings.md).
# Never put secrets in an item body or in a log entry.
#
# Usage:
#   fm-issue.sh show <id>
#   fm-issue.sh prime
#   fm-issue.sh parent <child-id> <parent-id>
#   fm-issue.sh unparent <child-id>
#   fm-issue.sh link <id> related|discovered-from <other-id>
#   fm-issue.sh unlink <id> related|discovered-from <other-id>
#   fm-issue.sh log <id> done|failed|followup|question|note [<text>...]
#   fm-issue.sh --help
#
# `log` reads its text from stdin when no text arguments are given, so a worker
# can pipe a failing command's last lines. Text is normalized to one line: tabs
# and newlines become spaces. `question` requires the item to be open and the
# captain hold to succeed before the log entry is recorded.
#
# Reads never take the lock. A mutation validates its ids against tasks-axi
# first, takes the sidecar lock for at most 10 seconds, appends one record, and
# releases it. `parent` refuses a cycle, a second parent, and a done parent.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TASKS_AXI="$SCRIPT_DIR/fm-tasks-axi.sh"
CAPTAIN_HOLD="$SCRIPT_DIR/fm-captain-hold.sh"
SIDECAR="$DATA/issue-index.tsv"
LOCK="$DATA/.issue-index.lock"
SIDECAR_HEADER='# fm-issue sidecar v1 - append only; readers ignore this line'

BODY_LIMIT=4000
CHILD_LIMIT=20
BLOCKER_LIMIT=12
LINK_LIMIT=10
LOG_LIMIT=8
LOG_TEXT_LIMIT=300

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'fm-issue: %s\n' "$*" >&2
  exit 2
}

valid_id() {  # <id>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

require_id() {  # <label> <id>
  valid_id "$2" || die "$1 is not a valid item id: $2"
}

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

# --- tasks-axi reads ---------------------------------------------------------

# Print `<state>\t<title>` for an id, or MISSING. One tasks-axi call.
task_summary_raw() {  # <id>
  "$TASKS_AXI" show "$1" 2>/dev/null | awk '
    /^  state: / { s = substr($0, 10) }
    /^  title: / {
      t = substr($0, 10)
      if (t ~ /^".*"$/) t = substr(t, 2, length(t) - 2)
    }
    END {
      if (s == "") { print "MISSING" }
      else { printf "%s\t%s\n", s, t }
    }
  '
}

item_state() {  # <id>; empty when absent
  local raw
  raw=$(task_summary_raw "$1") || return 1
  [ "$raw" = MISSING ] && return 1
  printf '%s' "${raw%%$'\t'*}"
}

require_item() {  # <id>
  local state
  state=$(item_state "$1") || die "no such item in this backlog: $1"
  [ -n "$state" ] || die "no such item in this backlog: $1"
}

summary_of() {  # <id>; `<id> [state] title`
  local raw state title
  raw=$(task_summary_raw "$1")
  if [ "$raw" = MISSING ]; then
    printf '%s [missing]' "$1"
    return 0
  fi
  state=${raw%%$'\t'*}
  title=${raw#*$'\t'}
  if [ -n "$title" ]; then
    printf '%s [%s] %s' "$1" "$state" "$title"
  else
    printf '%s [%s]' "$1" "$state"
  fi
}

# --- sidecar reads -----------------------------------------------------------

parent_of() {  # <child>
  [ -f "$SIDECAR" ] || return 0
  awk -F'\t' -v id="$1" '
    $1 == "link" && $2 == "parent" && $3 == id { p = $4 }
    $1 == "unlink" && $2 == "parent" && $3 == id { p = "" }
    END { if (p != "") print p }
  ' "$SIDECAR"
}

children_of() {  # <parent>
  [ -f "$SIDECAR" ] || return 0
  awk -F'\t' -v id="$1" '
    $1 == "link" && $2 == "parent" { p[$3] = $4 }
    $1 == "unlink" && $2 == "parent" { p[$3] = "" }
    END { for (x in p) if (p[x] == id) print x }
  ' "$SIDECAR" | LC_ALL=C sort
}

related_of() {  # <id>
  [ -f "$SIDECAR" ] || return 0
  awk -F'\t' -v id="$1" '
    $1 == "link" && $2 == "related" {
      if ($3 == id) r[$4] = 1; else if ($4 == id) r[$3] = 1
    }
    $1 == "unlink" && $2 == "related" {
      if ($3 == id) delete r[$4]; else if ($4 == id) delete r[$3]
    }
    END { for (x in r) print x }
  ' "$SIDECAR" | LC_ALL=C sort
}

discovered_from_of() {  # <id> -> origins this item was discovered from
  [ -f "$SIDECAR" ] || return 0
  awk -F'\t' -v id="$1" '
    $1 == "link" && $2 == "discovered-from" && $3 == id { r[$4] = 1 }
    $1 == "unlink" && $2 == "discovered-from" && $3 == id { delete r[$4] }
    END { for (x in r) print x }
  ' "$SIDECAR" | LC_ALL=C sort
}

discovered_in() {  # <id> -> items discovered while working on this one
  [ -f "$SIDECAR" ] || return 0
  awk -F'\t' -v id="$1" '
    $1 == "link" && $2 == "discovered-from" && $4 == id { r[$3] = 1 }
    $1 == "unlink" && $2 == "discovered-from" && $4 == id { delete r[$3] }
    END { for (x in r) print x }
  ' "$SIDECAR" | LC_ALL=C sort
}

link_present() {  # <type> <a> <b>
  [ -f "$SIDECAR" ] || return 1
  awk -F'\t' -v t="$1" -v a="$2" -v b="$3" '
    $1 == "link" && $2 == t && $3 == a && $4 == b { f = 1 }
    $1 == "unlink" && $2 == t && $3 == a && $4 == b { f = 0 }
    END { exit f ? 0 : 1 }
  ' "$SIDECAR"
}

log_count() {  # <id>
  [ -f "$SIDECAR" ] || { printf '0\n'; return 0; }
  awk -F'\t' -v id="$1" '$1 == "log" && $3 == id { n++ } END { print n + 0 }' "$SIDECAR"
}

# --- sidecar writes ----------------------------------------------------------

LOCK_LIB_LOADED=0
load_lock_lib() {
  [ "$LOCK_LIB_LOADED" = 1 ] && return 0
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  LOCK_LIB_LOADED=1
}

append_sidecar() {  # <tab-separated-record>
  mkdir -p "$DATA" 2>/dev/null || die "cannot create data directory $DATA"
  load_lock_lib
  fm_lock_acquire_wait_max "$LOCK" 10 || die "could not lock $LOCK within 10s"
  if [ ! -f "$SIDECAR" ]; then
    printf '%s\n' "$SIDECAR_HEADER" > "$SIDECAR" \
      || { fm_lock_release "$LOCK" || true; die "cannot create $SIDECAR"; }
  fi
  if ! printf '%s\n' "$1" >> "$SIDECAR"; then
    fm_lock_release "$LOCK" || true
    die "cannot append to $SIDECAR"
  fi
  fm_lock_release "$LOCK" || true
}

sanitize_text() {  # <text>; one line, no tabs or newlines
  printf '%s' "$1" | tr '\t\r\n' '   ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# --- commands ----------------------------------------------------------------

cmd_show() {
  [ "$#" -eq 1 ] || die "usage: fm-issue.sh show <id>"
  local id=$1 item parent kids kid st
  local total=0 done_count=0 open_count=0
  local active deps dep_line rel origins discoveries entry_count

  require_id id "$id"
  item=$("$TASKS_AXI" show "$id" --full 2>&1) \
    || { printf '%s\n' "$item" >&2; exit 1; }

  printf '%s\n' "$item" | awk -v lim="$BODY_LIMIT" -v id="$id" '
    /^  body: / && length($0) > lim + 8 {
      print substr($0, 1, lim + 8) "... (body truncated; bin/fm-tasks-axi.sh show " id " --full reads the whole row)"
      next
    }
    { print }
  '

  printf '\nissue-layer:\n'

  parent=$(parent_of "$id")
  if [ -n "$parent" ]; then
    printf '  parent: %s\n' "$(summary_of "$parent")"
  else
    printf '  parent: none\n'
  fi

  kids=$(children_of "$id")
  if [ -n "$kids" ]; then
    while IFS= read -r kid; do
      [ -n "$kid" ] || continue
      total=$((total + 1))
      st=$(item_state "$kid") || st="missing"
      [ "$st" = "done" ] && done_count=$((done_count + 1))
      [ "$st" = "done" ] || open_count=$((open_count + 1))
    done <<< "$kids"
    printf '  epic: %s/%s children done, %s open\n' "$done_count" "$total" "$open_count"
    if [ "$open_count" -gt 0 ]; then
      local shown=0
      while IFS= read -r kid; do
        [ -n "$kid" ] || continue
        st=$(item_state "$kid") || st="missing"
        [ "$st" = "done" ] && continue
        if [ "$shown" -ge "$CHILD_LIMIT" ]; then
          printf '    ... %s more open children\n' "$((open_count - shown))"
          break
        fi
        printf '    - %s\n' "$(summary_of "$kid")"
        shown=$((shown + 1))
      done <<< "$kids"
    fi
  fi

  active=$(printf '%s\n' "$item" | awk 'index($0, "  blocked_by: ") == 1 { print substr($0, 15); exit }')
  active=$(printf '%s' "$active" | sed -e 's/^"//' -e 's/"$//')
  [ "$active" = none ] && active=
  if [ -n "$active" ]; then
    printf '  blockers (open):\n'
    printf '%s\n' "$active" | tr ',' '\n' | awk 'NF { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' |
      head -n "$BLOCKER_LIMIT" |
      while IFS= read -r dep_line; do
        [ -n "$dep_line" ] || continue
        printf '    - %s\n' "$(summary_of "$dep_line")"
      done
  else
    printf '  blockers (open): none\n'
  fi

  deps=$(printf '%s\n' "$item" | awk 'index($0, "  deps: ") == 1 { print substr($0, 9); exit }')
  deps=$(printf '%s' "$deps" | sed -e 's/^"//' -e 's/"$//')
  [ "$deps" = none ] && deps=
  if [ -n "$deps" ]; then
    printf '  dependency edges:\n'
    printf '%s\n' "$deps" | tr ',' '\n' \
      | sed -e 's/^"//' -e 's/"$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      | sed -e 's/^blocked-by://' -e 's/^blocks://' -e 's/^depends-on://' \
      | awk 'NF' | head -n "$BLOCKER_LIMIT" |
      while IFS= read -r dep_line; do
        printf '    - %s\n' "$(summary_of "$dep_line")"
      done
  fi

  rel=$(related_of "$id")
  origins=$(discovered_from_of "$id")
  discoveries=$(discovered_in "$id")
  if [ -n "$rel" ] || [ -n "$origins" ] || [ -n "$discoveries" ]; then
    printf '  links:\n'
    if [ -n "$rel" ]; then
      printf '%s\n' "$rel" | head -n "$LINK_LIMIT" |
        while IFS= read -r kid; do
          [ -n "$kid" ] || continue
          printf '    - related: %s\n' "$(summary_of "$kid")"
        done
    fi
    if [ -n "$origins" ]; then
      printf '%s\n' "$origins" | head -n "$LINK_LIMIT" |
        while IFS= read -r kid; do
          [ -n "$kid" ] || continue
          printf '    - discovered from: %s\n' "$(summary_of "$kid")"
        done
    fi
    if [ -n "$discoveries" ]; then
      printf '%s\n' "$discoveries" | head -n "$LINK_LIMIT" |
        while IFS= read -r kid; do
          [ -n "$kid" ] || continue
          printf '    - discovered here: %s\n' "$(summary_of "$kid")"
        done
    fi
  else
    printf '  links: none\n'
  fi

  entry_count=$(log_count "$id")
  if [ "$entry_count" -gt 0 ]; then
    printf '  log: %s entries, most recent %s\n' "$entry_count" "$LOG_LIMIT"
    awk -F'\t' -v id="$id" '$1 == "log" && $3 == id' "$SIDECAR" |
      tail -n "$LOG_LIMIT" |
      while IFS=$'\t' read -r _ typ _ _ ts text; do
        if [ "${#text}" -gt "$LOG_TEXT_LIMIT" ]; then
          text="${text:0:$LOG_TEXT_LIMIT}..."
        fi
        printf '    - %s %s: %s\n' "$ts" "$typ" "$text"
      done
  else
    printf '  log: none\n'
  fi
}

cmd_prime() {
  cat <<'TEXT'
Issue layer (id-first):
- You are given an item id. Read everything known about it with:
    bin/fm-issue.sh show <id>
  That returns the item, its parent, open children, blockers, links, and recent log.
- Record what happened in the item, one line per event:
    bin/fm-issue.sh log <id> done|failed|followup|note "what/why"
- Link related work and work you found while here:
    bin/fm-issue.sh link <id> related|discovered-from <other-id>
- A feature is a parent item; each slice is its own item:
    bin/fm-issue.sh parent <child-id> <parent-id>
  Show the parent for done/total progress.
- A question that needs the captain: log it with type question. That also places
  the item under a captain hold; never answer it yourself.
- Row state, priority, blocking and ready work stay in tasks-axi:
    bin/fm-tasks-axi.sh show <id> | ready | block <id> --by <blocker> | done <id>
  Never parse or edit data/backlog.md.
TEXT
}

cmd_parent() {
  [ "$#" -eq 2 ] || die "usage: fm-issue.sh parent <child-id> <parent-id>"
  local child=$1 parent=$2 existing cur depth=0
  require_id "child id" "$child"
  require_id "parent id" "$parent"
  [ "$child" = "$parent" ] && die "an item cannot be its own parent"
  require_item "$child"
  require_item "$parent"
  [ "$(item_state "$parent")" = "done" ] && die "parent $parent is done; file the child under an open epic"
  existing=$(parent_of "$child")
  if [ "$existing" = "$parent" ]; then
    printf 'parent: %s -> %s (unchanged)\n' "$child" "$parent"
    return 0
  fi
  [ -n "$existing" ] && die "$child already has parent $existing; run 'fm-issue.sh unparent $child' first"
  cur=$parent
  while [ -n "$cur" ]; do
    [ "$cur" = "$child" ] && die "parent would create a cycle through $child"
    cur=$(parent_of "$cur")
    depth=$((depth + 1))
    [ "$depth" -gt 64 ] && die "parent chain is deeper than 64; refusing"
  done
  append_sidecar "$(printf 'link\tparent\t%s\t%s\t%s' "$child" "$parent" "$(now_utc)")"
  printf 'parent: %s -> %s\n' "$child" "$parent"
}

cmd_unparent() {
  [ "$#" -eq 1 ] || die "usage: fm-issue.sh unparent <child-id>"
  require_id "child id" "$1"
  append_sidecar "$(printf 'unlink\tparent\t%s\t-\t%s' "$1" "$(now_utc)")"
  printf 'unparent: %s\n' "$1"
}

cmd_link() {
  [ "$#" -eq 3 ] || die "usage: fm-issue.sh link <id> related|discovered-from <other-id>"
  local id=$1 type=$2 other=$3 a b
  require_id "item id" "$id"
  require_id "other id" "$other"
  [ "$id" = "$other" ] && die "an item cannot link to itself"
  case "$type" in
    related|discovered-from) ;;
    *) die "link type must be related or discovered-from" ;;
  esac
  require_item "$id"
  require_item "$other"
  if [ "$type" = related ]; then
    if [[ "$id" < "$other" ]]; then a=$id; b=$other; else a=$other; b=$id; fi
  else
    a=$id; b=$other
  fi
  if link_present "$type" "$a" "$b"; then
    printf 'link: %s %s %s (unchanged)\n' "$id" "$type" "$other"
    return 0
  fi
  append_sidecar "$(printf 'link\t%s\t%s\t%s\t%s' "$type" "$a" "$b" "$(now_utc)")"
  printf 'link: %s %s %s\n' "$id" "$type" "$other"
}

cmd_unlink() {
  [ "$#" -eq 3 ] || die "usage: fm-issue.sh unlink <id> related|discovered-from <other-id>"
  local id=$1 type=$2 other=$3 a b
  require_id "item id" "$id"
  require_id "other id" "$other"
  case "$type" in
    related|discovered-from) ;;
    *) die "link type must be related or discovered-from" ;;
  esac
  if [ "$type" = related ]; then
    if [[ "$id" < "$other" ]]; then a=$id; b=$other; else a=$other; b=$id; fi
  else
    a=$id; b=$other
  fi
  append_sidecar "$(printf 'unlink\t%s\t%s\t%s\t%s' "$type" "$a" "$b" "$(now_utc)")"
  printf 'unlink: %s %s %s\n' "$id" "$type" "$other"
}

cmd_log() {
  [ "$#" -ge 2 ] || die "usage: fm-issue.sh log <id> done|failed|followup|question|note [<text>...]"
  local id=$1 type=$2 text state
  shift 2
  require_id "item id" "$id"
  case "$type" in
    done|failed|followup|question|note) ;;
    *) die "log type must be done, failed, followup, question, or note" ;;
  esac
  require_item "$id"
  if [ "$#" -gt 0 ]; then
    text="$*"
  elif [ ! -t 0 ]; then
    text=$(cat)
  else
    die "log text is required (pass it as arguments or on stdin)"
  fi
  text=$(sanitize_text "$text")
  [ -n "$text" ] || die "log text is empty after normalization"
  if [ "$type" = question ]; then
    state=$(item_state "$id") || state=
    [ "$state" = "done" ] && die "$id is done; reopen it before holding a question on it"
    [ -x "$CAPTAIN_HOLD" ] || die "bin/fm-captain-hold.sh is missing; cannot record a captain question"
    "$CAPTAIN_HOLD" hold "$id" --reason "$text" >/dev/null \
      || die "captain hold refused the question; the log entry was not recorded"
  fi
  append_sidecar "$(printf 'log\t%s\t%s\t-\t%s\t%s' "$type" "$id" "$(now_utc)" "$text")"
  printf 'log: %s %s recorded\n' "$id" "$type"
  [ "$type" = question ] && printf 'hold: %s now waits for the captain\n' "$id"
  return 0
}

main() {
  local cmd=${1:-}
  case "$cmd" in
    -h|--help|help)
      usage
      ;;
    show|view)
      shift
      cmd_show "$@"
      ;;
    prime)
      shift
      [ "$#" -eq 0 ] || die "usage: fm-issue.sh prime"
      cmd_prime
      ;;
    parent)
      shift
      cmd_parent "$@"
      ;;
    unparent)
      shift
      cmd_unparent "$@"
      ;;
    link)
      shift
      cmd_link "$@"
      ;;
    unlink)
      shift
      cmd_unlink "$@"
      ;;
    log)
      shift
      cmd_log "$@"
      ;;
    '')
      die "a command is required; run 'fm-issue.sh --help'"
      ;;
    *)
      die "unknown command: $cmd (run 'fm-issue.sh --help')"
      ;;
  esac
}

main "$@"
