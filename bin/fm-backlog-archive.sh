#!/usr/bin/env bash
# fm-backlog-archive.sh - park open backlog items in a second tasks-axi
# markdown backlog and bring them back later, byte-exact.
#
# Usage: fm-backlog-archive.sh archive [--parked] [<id>...]
#        fm-backlog-archive.sh archive --list      (same as list)
#        fm-backlog-archive.sh unarchive <id>...   (alias: restore)
#        fm-backlog-archive.sh list                (alias: archived, archive-list)
#        fm-backlog-archive.sh --help
#
# Why this exists: `tasks-axi prune` is a one-way, positional bulk trim of a
# section into the configured Done archive, `reopen` reads only the live
# backlog, and `tasks-axi mv` refuses to move an item whose blocker is absent
# from the destination. The parked rows this command targets routinely point at
# blockers that stay live or were already pruned, so `mv` cannot move them.
# This is therefore a small raw-block mover on top of the same file format, not
# a second backlog store: each moved line keeps its exact bytes, holds, hold
# reasons, bodies, and blocked-by links, and the destination stays a valid
# tasks-axi markdown backlog (`tasks-axi list|show --file` reads it).
#
# Addressing matches bin/fm-backlog-transition-lib.sh's
# fm_backlog_tasks_axi_addressing (the same resolution bin/fm-tasks-axi.sh
# uses), so the live backlog is the home's configured one from any working
# directory. The archive defaults to `backlog-archive.md` beside that backlog
# and can be overridden with FM_BACKLOG_ARCHIVE_FILE. Only the markdown backend
# is supported.
#
# Semantics:
#   archive   Move open `## Queued` / `## In flight` items into the archive,
#             preserving their section. `--parked` selects every live row that
#             carries `(hold-kind: parked)`. Done history is refused: it belongs
#             to tasks-axi's configured Done archive.
#   unarchive Restore archived items to the live `## Queued` section.
#   list      Run `tasks-axi list` against the archive.
#
# Refusals preserve tasks-axi `mv`'s safety intent only where it protects live
# work: archiving refuses when a remaining live task still blocks on a moved id.
# A moved row's own blocked-by target may legitimately stay live or already be
# pruned, as the paused PC02 cluster's are, so that link is carried as-is rather
# than refusing the move. An absent id, an id already at the destination, and a
# noncanonical (single-space or tab) body continuation are refused too. Nothing
# moves when any refusal fires.
# Both files are rewritten through a temp file and rename under tasks-axi's own
# sidecar lock protocol (`.lock` files, same stale/wait release shape), with
# backups restored if the second write or the post-write read-back fails.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

fail() {
  printf 'fm-backlog-archive: %s\n' "$*" >&2
  exit 2
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

file_ends_with_lf() {
  local path=$1 last_byte
  [ -s "$path" ] || return 1
  last_byte=$(tail -c 1 "$path" | od -An -tx1 | tr -d '[:space:]')
  [ "$last_byte" = "0a" ]
}

backlog_key_section() {  # <file> <key>
  local file=$1 key=$2
  [ -f "$file" ] || return 1
  awk -v key="$key" '
    BEGIN { section = "## Queued" }
    /^## / { section = $0; next }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id == key) { print section; found = 1; exit }
      next
    }
    /^- \*\*/ {
      rest = $0
      sub(/^- \*\*/, "", rest)
      id = rest
      sub(/\*\*.*/, "", id)
      if (id == key) { print section; found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

backlog_key_noncanonical_body_lines() {  # <file> <key>
  local file=$1 key=$2
  awk -v key="$key" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (capturing) exit
      if (id == key) { capturing = 1 }
      next
    }
    /^- \*\*/ {
      rest = $0
      sub(/^- \*\*/, "", rest)
      id = rest
      sub(/\*\*.*/, "", id)
      if (capturing) exit
      if (id == key) { capturing = 1 }
      next
    }
    capturing && /^##[[:space:]]+/ { exit }
    capturing && /^[[:space:]]/ && !/^  / && /[^[:space:]]/ { print }
  ' "$file"
}

backlog_stranding_dependents() {  # <file> <space-separated moved ids>
  local file=$1 moved=$2
  awk -v moved="$moved" '
    BEGIN {
      n = split(moved, ids, " ")
      for (i = 1; i <= n; i++) if (ids[i] != "") want[ids[i]] = 1
    }
    function check(rest,    m, i) {
      i = 1
      while (match(rest, /(blocked-by|parent|discovered-from):[ \t]+[A-Za-z0-9][A-Za-z0-9._-]*/)) {
        m = substr(rest, RSTART, RLENGTH)
        sub(/^[^:]*:[ \t]+/, "", m)
        if (m in want) print owner "\t" m
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    /^## / { section = $0; next }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      owner = rest
      sub(/[ \t].*/, "", owner)
      if (!(owner in want) && section != "## Done") check(rest)
      next
    }
    /^- \*\*/ {
      rest = $0
      sub(/^- \*\*/, "", rest)
      owner = rest
      sub(/\*\*.*/, "", owner)
      if (!(owner in want) && section != "## Done") check(rest)
    }
  ' "$file"
}

backlog_parked_ids() {  # <file>
  local file=$1
  awk '
    BEGIN { section = "## Queued" }
    /^## / { section = $0; next }
    section == "## Done" { next }
    /^- \[ \] / && /\(hold-kind: parked\)/ {
      rest = $0
      sub(/^- \[ \] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      print id
    }
  ' "$file"
}

# --- argument parsing -------------------------------------------------------

MODE=${1:-}
case "$MODE" in
  -h | --help)
    usage
    exit 0
    ;;
  archive | unarchive | restore | list | archived | archive-list) ;;
  '')
    usage >&2
    exit 2
    ;;
  *)
    fail "unknown command '$MODE'; use archive, unarchive, restore, list, or --help"
    ;;
esac
shift

PARKED=0
LIST_ARCHIVE=0
IDS=()
case "$MODE" in
  archive)
    for arg in "$@"; do
      case "$arg" in
        --parked) PARKED=1 ;;
        --list) LIST_ARCHIVE=1 ;;
        --parked=*)
          fail "--parked does not take a value"
          ;;
        -h | --help)
          usage
          exit 0
          ;;
        -*)
          fail "unknown archive flag '$arg'"
          ;;
        *) IDS+=("$arg") ;;
      esac
    done
    ;;
  unarchive | restore)
    for arg in "$@"; do
      case "$arg" in
        -h | --help)
          usage
          exit 0
          ;;
        -*)
          fail "unknown unarchive flag '$arg'"
          ;;
        *) IDS+=("$arg") ;;
      esac
    done
    ;;
  list | archived | archive-list)
    [ "$#" -eq 0 ] || fail "$MODE takes no arguments"
    ;;
esac

for id in ${IDS[@]+"${IDS[@]}"}; do
  case "$id" in
    '' | *[!A-Za-z0-9._-]*)
      fail "unsafe task id '$id'"
      ;;
  esac
done

# --- addressing -------------------------------------------------------------

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi
[ -n "$FM_BACKLOG_AXI_FILE" ] || fail "the parked archive requires the markdown backlog backend"

BACKLOG="$FM_BACKLOG_AXI_FILE"
CALLER_DIR=$(pwd)
if [ -n "${FM_BACKLOG_ARCHIVE_FILE:-}" ]; then
  case "$FM_BACKLOG_ARCHIVE_FILE" in
    /*) ARCHIVE="$FM_BACKLOG_ARCHIVE_FILE" ;;
    *) ARCHIVE="$CALLER_DIR/$FM_BACKLOG_ARCHIVE_FILE" ;;
  esac
else
  case "$BACKLOG" in
    */*) ARCHIVE="${BACKLOG%/*}/backlog-archive.md" ;;
    *) ARCHIVE="backlog-archive.md" ;;
  esac
fi

[ -e "$BACKLOG" ] || fail "no markdown backlog at $BACKLOG"
[ -L "$BACKLOG" ] && fail "$BACKLOG is a symlink; make it this home's real file"
[ -L "$ARCHIVE" ] && fail "$ARCHIVE is a symlink; make it this home's real file"
case "$ARCHIVE" in
  "$BACKLOG") fail "the archive path must differ from the live backlog" ;;
esac

if [ "$MODE" = list ] || [ "$MODE" = archived ] || [ "$MODE" = archive-list ] ||
  { [ "$MODE" = archive ] && [ "$LIST_ARCHIVE" = 1 ]; }; then
  [ "${#IDS[@]}" -eq 0 ] || fail "--list takes no task ids"
  [ "$PARKED" = 0 ] || fail "--list does not combine with --parked"
  ( cd "$FM_BACKLOG_AXI_ROOT" && exec tasks-axi list --file "$ARCHIVE" )
  exit $?
fi

case "$MODE" in
  archive)
    SRC_FILE="$BACKLOG"
    DST_FILE="$ARCHIVE"
    FORCE_SECTION=
    ACTION=archived
    ;;
  unarchive | restore)
    SRC_FILE="$ARCHIVE"
    DST_FILE="$BACKLOG"
    FORCE_SECTION="## Queued"
    ACTION=unarchived
    ;;
esac

# --- selection --------------------------------------------------------------

if [ "$PARKED" = 1 ]; then
  [ "$MODE" = archive ] || fail "--parked is only valid with archive"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    IDS+=("$id")
  done < <(backlog_parked_ids "$BACKLOG")
fi

if [ "${#IDS[@]}" -eq 0 ]; then
  if [ "$PARKED" = 1 ]; then
    fail "no parked rows found in $BACKLOG"
  fi
  fail "no task ids given"
fi

# Drop duplicate ids after their first occurrence.
UNIQUE=()
for id in ${IDS[@]+"${IDS[@]}"}; do
  duplicate=0
  for seen in ${UNIQUE[@]+"${UNIQUE[@]}"}; do
    [ "$seen" = "$id" ] && duplicate=1 && break
  done
  [ "$duplicate" = 1 ] || UNIQUE+=("$id")
done

# --- classification ---------------------------------------------------------

TO_MOVE=()
ALREADY=()
MISSING=()
DONE=()
for id in ${UNIQUE[@]+"${UNIQUE[@]}"}; do
  if backlog_key_section "$DST_FILE" "$id" >/dev/null; then
    ALREADY+=("$id")
    continue
  fi
  if section=$(backlog_key_section "$SRC_FILE" "$id"); then
    case "$section" in
      "## Done")
        DONE+=("$id")
        ;;
      *)
        TO_MOVE+=("$id")
        ;;
    esac
  else
    MISSING+=("$id")
  fi
done

FAILED=0
if [ "${#MISSING[@]}" -gt 0 ]; then
  printf 'fm-backlog-archive: no item matched these ids in %s: %s\n' "$SRC_FILE" "${MISSING[*]}" >&2
  FAILED=1
fi
if [ "${#ALREADY[@]}" -gt 0 ]; then
  printf 'fm-backlog-archive: already in %s: %s\n' "$DST_FILE" "${ALREADY[*]}" >&2
  FAILED=1
fi
if [ "${#DONE[@]}" -gt 0 ]; then
  printf 'fm-backlog-archive: refusing Done (historical) items: %s; Done history belongs to tasks-axi'"'"'s configured Done archive\n' "${DONE[*]}" >&2
  FAILED=1
fi
if [ "$FAILED" -ne 0 ]; then
  printf 'fm-backlog-archive: nothing was moved\n' >&2
  exit 2
fi

if [ "${#TO_MOVE[@]}" -eq 0 ]; then
  printf 'nothing to move\n'
  exit 0
fi

for id in "${TO_MOVE[@]}"; do
  while IFS= read -r line; do
    printf 'fm-backlog-archive: refusing %s: non-2-space continuation line: %s\n' "$id" "$line" >&2
    FAILED=1
  done < <(backlog_key_noncanonical_body_lines "$SRC_FILE" "$id")
done
if [ "$FAILED" -ne 0 ]; then
  printf 'fm-backlog-archive: nothing was moved\n' >&2
  exit 2
fi

if [ "$MODE" = archive ]; then
  moved_space=${TO_MOVE[*]}
  STRANDED=$(backlog_stranding_dependents "$BACKLOG" "$moved_space")
  if [ -n "$STRANDED" ]; then
    while IFS=$'\t' read -r dependent blocker; do
      [ -n "$dependent" ] || continue
      printf 'fm-backlog-archive: refusing %s: live task %s is still blocked by it; archive or move the dependent too\n' "$blocker" "$dependent" >&2
    done <<< "$STRANDED"
    printf 'fm-backlog-archive: nothing was moved\n' >&2
    exit 2
  fi
fi

# --- lock both files with tasks-axi's sidecar protocol ----------------------

LOCK_PATHS=()
for candidate in "$SRC_FILE" "$DST_FILE"; do
  LOCK_PATHS+=("$candidate.lock")
done
SORTED_LOCKS=$(printf '%s\n' "${LOCK_PATHS[@]}" | LC_ALL=C sort)
HELD_LOCKS=()
release_locks() {
  local entry path token observed
  for entry in ${HELD_LOCKS[@]+"${HELD_LOCKS[@]}"}; do
    path=${entry%%$'\t'*}
    token=${entry#*$'\t'}
    observed=""
    [ -f "$path" ] && observed=$(cat "$path" 2>/dev/null || true)
    [ "$observed" = "$token" ] && rm -f "$path"
  done
}
trap release_locks EXIT

lock_age_seconds() {  # <path>
  perl -e 'my @s = stat($ARGV[0]); exit 1 unless @s; my $age = time - $s[9]; print $age < 0 ? 0 : $age' "$1" 2>/dev/null
}

acquire_lock() {  # <path>
  local path=$1 token deadline now age
  token="$$:$(date +%s):fm-backlog-archive"
  deadline=$(( $(date +%s) + 3 ))
  while :; do
    if (set -o noclobber; printf '%s\n' "$token" > "$path") 2>/dev/null; then
      HELD_LOCKS+=("$path"$'\t'"$token")
      return 0
    fi
    if age=$(lock_age_seconds "$path") && [ "$age" -gt 30 ]; then
      printf 'fm-backlog-archive: backlog lock looks stale: %s\n' "$path" >&2
      return 2
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      printf 'fm-backlog-archive: backlog is locked by another process: %s\n' "$path" >&2
      return 1
    fi
    sleep 0.05
  done
}

while IFS= read -r lock_path; do
  [ -n "$lock_path" ] || continue
  acquire_lock "$lock_path" || exit 2
done <<< "$SORTED_LOCKS"

# --- move -------------------------------------------------------------------

DST_EXISTED=0
[ -e "$DST_FILE" ] && DST_EXISTED=1
SRC_DIR=$(dirname "$SRC_FILE")
DST_DIR=$(dirname "$DST_FILE")
mkdir -p "$SRC_DIR" "$DST_DIR"
KEYS_FILE=$(mktemp "$SRC_DIR/.fm-backlog-archive-keys.XXXXXX")
MOVED_FILE=$(mktemp "$SRC_DIR/.fm-backlog-archive-moved.XXXXXX")
KEPT_FILE=$(mktemp "$SRC_DIR/.fm-backlog-archive-kept.XXXXXX")
DST_TMP=$(mktemp "$DST_DIR/.fm-backlog-archive-dst.XXXXXX")
SRC_BAK=$(mktemp "$SRC_DIR/.fm-backlog-archive-src-bak.XXXXXX")
DST_BAK=$(mktemp "$DST_DIR/.fm-backlog-archive-dst-bak.XXXXXX")
CHANGES_STARTED=0
COMMITTED=0
cleanup_files() {
  if [ "$CHANGES_STARTED" -eq 1 ] && [ "$COMMITTED" -eq 0 ]; then
    cp "$SRC_BAK" "$SRC_FILE" 2>/dev/null || true
    if [ "$DST_EXISTED" -eq 1 ]; then
      cp "$DST_BAK" "$DST_FILE" 2>/dev/null || true
    else
      rm -f "$DST_FILE"
    fi
  fi
  rm -f "$KEYS_FILE" "$MOVED_FILE" "$KEPT_FILE" "$DST_TMP" "$SRC_BAK" "$DST_BAK"
}
trap 'cleanup_files; release_locks' EXIT
trap 'exit 2' HUP INT TERM

printf '%s\n' "${TO_MOVE[@]}" > "$KEYS_FILE"
cp "$SRC_FILE" "$SRC_BAK"
[ "$DST_EXISTED" -eq 1 ] && cp "$DST_FILE" "$DST_BAK"
CHANGES_STARTED=1

if [ "$DST_EXISTED" -eq 0 ]; then
  mkdir -p "$DST_DIR"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$DST_FILE"
fi

: > "$MOVED_FILE"
SRC_FINAL_LF=0
file_ends_with_lf "$SRC_FILE" && SRC_FINAL_LF=1
awk -v keysfile="$KEYS_FILE" -v movedfile="$MOVED_FILE" -v keptfile="$KEPT_FILE" \
  -v final_lf="$SRC_FINAL_LF" -v force_section="$FORCE_SECTION" '
  function emit_kept(rec) {
    if (have_kept) print pending_kept > keptfile
    pending_kept = rec
    have_kept = 1
  }
  function emit_moved(rec) {
    if (have_moved) print pending_moved > movedfile
    pending_moved = rec
    have_moved = 1
  }
  function move_section() {
    return force_section != "" ? force_section : section
  }
  BEGIN {
    while ((getline k < keysfile) > 0) { if (k != "") want[k] = 1 }
    section = "## Queued"
    moving = 0
  }
  /^## / {
    moving = 0
    section = $0
    emit_kept($0)
    last_source_kept = 1
    last_source_moved = 0
    next
  }
  /^- \[[ x]\] / {
    rest = $0
    sub(/^- \[[ x]\] +/, "", rest)
    id = rest
    sub(/[ \t].*/, "", id)
    if (id in want) {
      emit_moved(move_section() "\t" $0)
      moving = 1
      last_source_kept = 0
      last_source_moved = 1
      next
    }
    moving = 0
    emit_kept($0)
    last_source_kept = 1
    last_source_moved = 0
    next
  }
  /^- \*\*/ {
    rest = $0
    sub(/^- \*\*/, "", rest)
    id = rest
    sub(/\*\*.*/, "", id)
    if (id in want) {
      emit_moved(move_section() "\t" $0)
      moving = 1
      last_source_kept = 0
      last_source_moved = 1
      next
    }
    moving = 0
    emit_kept($0)
    last_source_kept = 1
    last_source_moved = 0
    next
  }
  moving && /^([ \t].*)?$/ {
    emit_moved(move_section() "\t" $0)
    last_source_kept = 0
    last_source_moved = 1
    next
  }
  {
    moving = 0
    emit_kept($0)
    last_source_kept = 1
    last_source_moved = 0
  }
  END {
    if (have_kept) {
      if (last_source_kept && !final_lf) printf "%s", pending_kept > keptfile
      else print pending_kept > keptfile
    }
    if (have_moved) {
      if (last_source_moved && !final_lf) printf "%s", pending_moved > movedfile
      else print pending_moved > movedfile
    }
  }
' "$SRC_FILE"

MOVED_FINAL_LF=0
file_ends_with_lf "$MOVED_FILE" && MOVED_FINAL_LF=1
awk -v movedfile="$MOVED_FILE" -v moved_final_lf="$MOVED_FINAL_LF" '
  function add_record(rec, eol,    tab, sec, line) {
    tab = index(rec, "\t")
    if (tab == 0) return
    sec = substr(rec, 1, tab - 1)
    line = substr(rec, tab + 1)
    if (!(sec in items)) { order[++nsec] = sec }
    items[sec] = items[sec] line eol
  }
  function flush(sec, needs_separator) {
    if (sec != "" && (sec in items) && !(sec in flushed)) {
      printf "%s", items[sec]
      if (needs_separator && items[sec] !~ /\n$/) printf "\n"
      flushed[sec] = 1
    }
  }
  BEGIN {
    nsec = 0
    have_pending = 0
    while ((getline rec < movedfile) > 0) {
      if (have_pending) add_record(pending, "\n")
      pending = rec
      have_pending = 1
    }
    if (have_pending) {
      add_record(pending, moved_final_lf ? "\n" : "")
    }
    cur = ""
  }
  /^## / { flush(cur, 1); cur = $0; print; next }
  { print }
  END {
    needs_separator = 0
    for (i = 1; i <= nsec; i++) {
      if (!(order[i] in flushed) && order[i] != cur) {
        needs_separator = 1
        break
      }
    }
    flush(cur, needs_separator)
    for (i = 1; i <= nsec; i++) {
      s = order[i]
      if (!(s in flushed)) {
        print ""
        print s
        printf "%s", items[s]
        flushed[s] = 1
      }
    }
  }
' "$DST_FILE" > "$DST_TMP"

mv "$DST_TMP" "$DST_FILE"
mv "$KEPT_FILE" "$SRC_FILE"

# Read-back proves every moved id is readable at the destination and the live
# file still parses. A failure restores both backups before reporting.
VALID=1
if ! ( cd "$FM_BACKLOG_AXI_ROOT" && tasks-axi list --file "$SRC_FILE" >/dev/null 2>&1 ); then
  VALID=0
fi
if ! ( cd "$FM_BACKLOG_AXI_ROOT" && tasks-axi list --file "$DST_FILE" >/dev/null 2>&1 ); then
  VALID=0
fi
for id in "${TO_MOVE[@]}"; do
  ( cd "$FM_BACKLOG_AXI_ROOT" && tasks-axi show "$id" --file "$DST_FILE" >/dev/null 2>&1 ) || VALID=0
done
if [ "$VALID" -eq 0 ]; then
  printf 'fm-backlog-archive: read-back failed; restoring both files\n' >&2
  exit 2
fi
COMMITTED=1

printf '%s %d item(s) via %s: %s\n' "$ACTION" "${#TO_MOVE[@]}" "$ARCHIVE" "${TO_MOVE[*]}"
printf '  live backlog: %s\n' "$BACKLOG"
