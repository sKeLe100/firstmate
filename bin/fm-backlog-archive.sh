#!/usr/bin/env bash
# fm-backlog-archive.sh - park open backlog items in a second tasks-axi
# markdown backlog and bring them back later, byte-exact.
#
# Usage: fm-backlog-archive.sh archive <id>...
#        fm-backlog-archive.sh unarchive <id>...
#        fm-backlog-archive.sh archived
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
# directory. The archive is always `backlog-archive.md` beside that backlog.
# Only the markdown backend is supported.
#
# Semantics:
#   archive   Move the named open `## Queued` items into the archive's
#             `## Queued` section.
#   unarchive Restore the named archived items to the live `## Queued` section.
#   archived  Run `tasks-axi list` against the archive.
#
# Refusals (nothing moves when any fires):
#   - an absent id, or an id already at the destination;
#   - a Done item, which belongs to tasks-axi's configured Done archive;
#   - archiving an `## In flight` item or one with a `state/<id>.meta` record in
#     this home (FM_STATE_OVERRIDE, else $FM_HOME/state);
#   - archiving a row that a remaining live task still depends on;
#   - unarchiving a row whose blocked-by target is still open in the archive and
#     is neither selected in the same call nor already live. A target that is
#     live or absent from the archive (pruned or finished) is allowed;
#   - a noncanonical (single-space or tab) body continuation.
# Selection, refusals, and the move all run under tasks-axi's own sidecar lock
# protocol (`.lock` files, same stale/wait release shape). Both files are
# rewritten through a temp file and rename that keeps their modes, with backups
# restored if any write or the post-write read-back fails.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
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

# Prints "owner<TAB>type<TAB>target" for every open row's dependency edge.
backlog_open_edges() {  # <file>
  local file=$1
  awk '
    function edges(rest,    m, type) {
      while (match(rest, /(blocked-by|parent|discovered-from):[ \t]*[A-Za-z0-9][A-Za-z0-9._-]*/)) {
        m = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        type = m
        sub(/:.*/, "", type)
        sub(/^[^:]*:[ \t]*/, "", m)
        print owner "\t" type "\t" m
      }
    }
    /^## / { section = $0; next }
    section == "## Done" { next }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      owner = rest
      sub(/[ \t].*/, "", owner)
      edges(rest)
      next
    }
    /^- \*\*/ {
      rest = $0
      sub(/^- \*\*/, "", rest)
      owner = rest
      sub(/\*\*.*/, "", owner)
      edges(rest)
    }
  ' "$file"
}

is_selected() {  # <id>
  local selected
  for selected in ${TO_MOVE[@]+"${TO_MOVE[@]}"}; do
    [ "$selected" = "$1" ] && return 0
  done
  return 1
}

# --- argument parsing -------------------------------------------------------

MODE=${1:-}
case "$MODE" in
  -h | --help)
    usage
    exit 0
    ;;
  archive | unarchive | archived) ;;
  '')
    usage >&2
    exit 2
    ;;
  *)
    fail "unknown command '$MODE'; use archive, unarchive, archived, or --help"
    ;;
esac
shift

IDS=()
for arg in "$@"; do
  case "$arg" in
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      fail "unknown $MODE flag '$arg'"
      ;;
    *) IDS+=("$arg") ;;
  esac
done
if [ "$MODE" = archived ]; then
  [ "${#IDS[@]}" -eq 0 ] || fail "archived takes no arguments"
else
  [ "${#IDS[@]}" -gt 0 ] || fail "no task ids given"
fi

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
ARCHIVE="${BACKLOG%/*}/backlog-archive.md"

[ -e "$BACKLOG" ] || fail "no markdown backlog at $BACKLOG"
[ -L "$BACKLOG" ] && fail "$BACKLOG is a symlink; make it this home's real file"
[ -L "$ARCHIVE" ] && fail "$ARCHIVE is a symlink; make it this home's real file"

case "$MODE" in
  archived)
    ( cd "$FM_BACKLOG_AXI_ROOT" && exec tasks-axi list --file "$ARCHIVE" )
    exit $?
    ;;
  archive)
    SRC_FILE="$BACKLOG"
    DST_FILE="$ARCHIVE"
    ACTION=archived
    ;;
  unarchive)
    SRC_FILE="$ARCHIVE"
    DST_FILE="$BACKLOG"
    ACTION=unarchived
    ;;
esac

# --- lock both files with tasks-axi's sidecar protocol ----------------------

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

for lock_path in "$ARCHIVE.lock" "$BACKLOG.lock"; do
  acquire_lock "$lock_path" || exit 2
done

# --- selection --------------------------------------------------------------

# Drop duplicate ids after their first occurrence.
UNIQUE=()
for id in "${IDS[@]}"; do
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
ACTIVE=()
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
        if [ "$MODE" = archive ] && { [ "$section" = "## In flight" ] || [ -e "$STATE/$id.meta" ]; }; then
          ACTIVE+=("$id")
        else
          TO_MOVE+=("$id")
        fi
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
if [ "${#ACTIVE[@]}" -gt 0 ]; then
  printf 'fm-backlog-archive: refusing In flight items or items with a task record: %s\n' "${ACTIVE[*]}" >&2
  FAILED=1
fi
if [ "$FAILED" -ne 0 ]; then
  printf 'fm-backlog-archive: nothing was moved\n' >&2
  exit 2
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

while IFS=$'\t' read -r owner type target; do
  if [ "$MODE" = archive ]; then
    if is_selected "$target" && ! is_selected "$owner"; then
      printf 'fm-backlog-archive: refusing %s: live task %s is still blocked by it; archive or move the dependent too\n' "$target" "$owner" >&2
      FAILED=1
    fi
  elif [ "$type" = blocked-by ] && is_selected "$owner" && ! is_selected "$target" &&
    section=$(backlog_key_section "$ARCHIVE" "$target") && [ "$section" != "## Done" ] &&
    ! backlog_key_section "$BACKLOG" "$target" >/dev/null; then
    printf 'fm-backlog-archive: refusing %s: its blocker %s is still parked; unarchive both together\n' "$owner" "$target" >&2
    FAILED=1
  fi
done < <(backlog_open_edges "$SRC_FILE")
if [ "$FAILED" -ne 0 ]; then
  printf 'fm-backlog-archive: nothing was moved\n' >&2
  exit 2
fi

# --- move -------------------------------------------------------------------

DST_EXISTED=0
[ -e "$DST_FILE" ] && DST_EXISTED=1
DATA_DIR=${BACKLOG%/*}
KEYS_FILE=
MOVED_FILE=
KEPT_FILE=
DST_TMP=
SRC_BAK=
DST_BAK=
CHANGES_STARTED=0
COMMITTED=0
cleanup_files() {
  if [ "$CHANGES_STARTED" -eq 1 ] && [ "$COMMITTED" -eq 0 ]; then
    if ! mv "$SRC_BAK" "$SRC_FILE"; then
      printf 'fm-backlog-archive: could not restore %s; its backup is %s\n' "$SRC_FILE" "$SRC_BAK" >&2
      SRC_BAK=
    fi
    if [ "$DST_EXISTED" -eq 0 ]; then
      rm -f "$DST_FILE"
    elif ! mv "$DST_BAK" "$DST_FILE"; then
      printf 'fm-backlog-archive: could not restore %s; its backup is %s\n' "$DST_FILE" "$DST_BAK" >&2
      DST_BAK=
    fi
  fi
  rm -f "$KEYS_FILE" "$MOVED_FILE" "$KEPT_FILE" "$DST_TMP" "$SRC_BAK" "$DST_BAK"
}
trap 'cleanup_files; release_locks' EXIT
trap 'exit 2' HUP INT TERM

make_temp() {  # <label>
  mktemp "$DATA_DIR/.fm-backlog-archive-$1.XXXXXX" || fail "cannot create a temporary file in $DATA_DIR; nothing was moved"
}
KEYS_FILE=$(make_temp keys) || exit 2
MOVED_FILE=$(make_temp moved) || exit 2
KEPT_FILE=$(make_temp kept) || exit 2
DST_TMP=$(make_temp dst) || exit 2
SRC_BAK=$(make_temp src-bak) || exit 2
DST_BAK=$(make_temp dst-bak) || exit 2

printf '%s\n' "${TO_MOVE[@]}" > "$KEYS_FILE" || fail "cannot record the selected ids; nothing was moved"
cp -p "$SRC_FILE" "$SRC_BAK" || fail "cannot back up $SRC_FILE; nothing was moved"
if [ "$DST_EXISTED" -eq 1 ]; then
  cp -p "$DST_FILE" "$DST_BAK" || fail "cannot back up $DST_FILE; nothing was moved"
fi
CHANGES_STARTED=1

if [ "$DST_EXISTED" -eq 0 ]; then
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$DST_FILE" || fail "cannot create $DST_FILE"
fi

# Copying first gives each replacement its original's mode before the rewrite.
cp -p "$SRC_FILE" "$KEPT_FILE" || fail "cannot prepare the rewrite of $SRC_FILE"
: > "$KEPT_FILE" || fail "cannot prepare the rewrite of $SRC_FILE"
cp -p "$DST_FILE" "$DST_TMP" || fail "cannot prepare the rewrite of $DST_FILE"

SRC_FINAL_LF=0
file_ends_with_lf "$SRC_FILE" && SRC_FINAL_LF=1
awk -v keysfile="$KEYS_FILE" -v movedfile="$MOVED_FILE" -v keptfile="$KEPT_FILE" \
  -v final_lf="$SRC_FINAL_LF" '
  function emit_kept(rec) {
    if (have_kept) print pending_kept > keptfile
    pending_kept = rec
    have_kept = 1
    last = "kept"
  }
  function emit_moved(rec) {
    if (have_moved) print pending_moved > movedfile
    pending_moved = rec
    have_moved = 1
    last = "moved"
  }
  function release_blanks(to_moved,    i) {
    for (i = 1; i <= blanks; i++) {
      if (to_moved) emit_moved(blank[i])
      else emit_kept(blank[i])
    }
    blanks = 0
  }
  function bullet(id) {
    moving = (id in want)
    if (moving) emit_moved($0)
    else emit_kept($0)
  }
  BEGIN {
    while ((getline k < keysfile) > 0) { if (k != "") want[k] = 1 }
  }
  moving && /^[ \t]*$/ { blank[++blanks] = $0; next }
  { release_blanks(!/^## /) }
  /^## / {
    moving = 0
    emit_kept($0)
    next
  }
  /^- \[[ x]\] / {
    rest = $0
    sub(/^- \[[ x]\] +/, "", rest)
    sub(/[ \t].*/, "", rest)
    bullet(rest)
    next
  }
  /^- \*\*/ {
    rest = $0
    sub(/^- \*\*/, "", rest)
    sub(/\*\*.*/, "", rest)
    bullet(rest)
    next
  }
  moving && /^[ \t]/ { emit_moved($0); next }
  {
    moving = 0
    emit_kept($0)
  }
  END {
    release_blanks(0)
    if (have_kept) {
      if (last == "kept" && !final_lf) printf "%s", pending_kept > keptfile
      else print pending_kept > keptfile
    }
    if (have_moved) {
      if (last == "moved" && !final_lf) printf "%s", pending_moved > movedfile
      else print pending_moved > movedfile
    }
  }
' "$SRC_FILE" || fail "cannot rewrite $SRC_FILE"

MOVED_FINAL_LF=0
file_ends_with_lf "$MOVED_FILE" && MOVED_FINAL_LF=1
awk -v movedfile="$MOVED_FILE" -v moved_final_lf="$MOVED_FINAL_LF" '
  function release_blanks(    i) {
    for (i = 1; i <= blanks; i++) print blank[i]
    blanks = 0
  }
  function insert(followed) {
    printf "%s", items
    if (followed && !moved_final_lf) printf "\n"
    inserted = 1
  }
  BEGIN {
    while ((getline rec < movedfile) > 0) items = items (count++ ? "\n" : "") rec
    if (moved_final_lf) items = items "\n"
  }
  queued && /^[ \t]*$/ { blank[++blanks] = $0; next }
  /^## / {
    if (queued) insert(1)
    release_blanks()
    queued = !inserted && $0 == "## Queued"
    print
    next
  }
  {
    release_blanks()
    print
  }
  END {
    if (queued) insert(blanks)
    release_blanks()
    if (!inserted) {
      printf "\n## Queued\n"
      insert(0)
    }
  }
' "$DST_FILE" > "$DST_TMP" || fail "cannot rewrite $DST_FILE"

mv "$DST_TMP" "$DST_FILE" || fail "cannot replace $DST_FILE"
mv "$KEPT_FILE" "$SRC_FILE" || fail "cannot replace $SRC_FILE"

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
