#!/usr/bin/env bash
# fm-upstream-sync-item.sh - file-or-refresh the ONE stable-id upstream sync
# backlog item for an open drift episode, and report auto-dispatch eligibility.
#
# Called by bin/fm-upstream-behind-check.sh's `check` action whenever an
# upstream drift episode is open (docs/configuration.md "Upstream autosync").
# This script never spawns a
# crewmate itself - bin/fm-spawn.sh and firstmate's own supervision loop own
# that decision, driven by this script's eligible= field.
#
# STABLE ID, NEVER DUPLICATED. The backlog item always uses the fixed id
# `upstream-sync`, so a later call with a bigger drift episode refreshes the
# same item's note in place instead of filing a second one. This mirrors the
# drift check's own episode-dedup shape (one open episode = one open task) and
# adds no second concurrency mechanism.
#
# BACKEND. Uses tasks-axi when bin/fm-tasks-axi-lib.sh reports it available and
# compatible, per config/backlog-backend (AGENTS.md section 10); otherwise
# hand-edits data/backlog.md the same way firstmate does when the backend is
# `manual`, upserting the block between the `<!-- upstream-sync:start -->` and
# `<!-- upstream-sync:end -->` markers.
#
# THRESHOLD AND ELIGIBILITY. Auto-dispatch is gated on the LOCAL, gitignored
# `config/upstream-autosync` presence flag (absent = today's ask-only behavior,
# unchanged) and on `behind >= FM_UPSTREAM_AUTOSYNC_COMMIT_THRESHOLD` (default
# 5) or `days_behind >= FM_UPSTREAM_AUTOSYNC_DAYS_THRESHOLD` (default 14),
# whichever the caller-supplied `behind` and `newest_upstream_date` cross
# first. This script only signals eligibility; it never dispatches.
#
# Usage:
#   fm-upstream-sync-item.sh file <behind> <newest_upstream_date> <default-branch>
#     Files or refreshes the backlog item and prints:
#       item_id=upstream-sync
#       action=filed|refreshed|skipped
#       behind=<N>
#       days_behind=<N>|unknown
#       eligible=yes|no
#       eligible_reason=<why>
#       overlap_count=<N>
#       overlap=<path>            (one line per overlapping file, bounded)
#
# FM_UPSTREAM_AUTOSYNC_COMMIT_THRESHOLD / FM_UPSTREAM_AUTOSYNC_DAYS_THRESHOLD
# override the thresholds (tests use them). FM_UPSTREAM_AUTOSYNC_OVERLAP_SHOWN
# bounds the printed overlap list (default 20).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

ITEM_ID=upstream-sync
ITEM_KIND=ship
ITEM_REPO=firstmate
BACKLOG_MD="$FM_HOME/data/backlog.md"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BACKLOG_WRITE_LOCK="$STATE/.fm-upstream-sync-item.lock"
MARK_START="<!-- upstream-sync:start -->"
MARK_END="<!-- upstream-sync:end -->"

usage() {
  sed -n '2,/^set -u/p' "$SCRIPT_DIR/fm-upstream-sync-item.sh" | sed -n 's/^# \{0,1\}//p'
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

[ "${1:-}" = file ] || { usage >&2; exit 1; }
behind=${2:-}
newest=${3:-}
default=${4:-}
case "$behind" in ''|*[!0-9]*) echo "error: <behind> must be a non-negative integer" >&2; exit 1 ;; esac
[ -n "$default" ] || { echo "error: <default-branch> is required" >&2; exit 1; }

# --- days behind, from newest_upstream_date (YYYY-MM-DD) to today -----------
days_behind=unknown
if [ -n "$newest" ] && [ "$newest" != unknown ]; then
  now_epoch=$(date +%s)
  if [ "$(uname)" = Darwin ]; then
    newest_epoch=$(date -j -f %Y-%m-%d "$newest" +%s 2>/dev/null) || newest_epoch=
  else
    newest_epoch=$(date -d "$newest" +%s 2>/dev/null) || newest_epoch=
  fi
  if [ -n "$newest_epoch" ]; then
    diff=$(( (now_epoch - newest_epoch) / 86400 ))
    [ "$diff" -ge 0 ] || diff=0
    days_behind=$diff
  fi
fi

# --- commit log delta and files-touched overlap -----------------------------
log_delta=$(git -C "$FM_ROOT" log --oneline \
  "refs/heads/$default..refs/remotes/upstream/$default" 2>/dev/null)

merge_base=$(git -C "$FM_ROOT" merge-base "refs/heads/$default" "refs/remotes/upstream/$default" 2>/dev/null) || merge_base=
upstream_files=""
local_files=""
if [ -n "$merge_base" ]; then
  upstream_files=$(git -C "$FM_ROOT" diff --name-only "$merge_base" "refs/remotes/upstream/$default" 2>/dev/null)
  local_files=$(git -C "$FM_ROOT" diff --name-only "$merge_base" "refs/heads/$default" 2>/dev/null)
fi
overlap=""
if [ -n "$upstream_files" ] && [ -n "$local_files" ]; then
  overlap=$(comm -12 <(printf '%s\n' "$upstream_files" | sort -u) \
                     <(printf '%s\n' "$local_files" | sort -u))
fi
overlap_count=0
[ -z "$overlap" ] || overlap_count=$(printf '%s\n' "$overlap" | sed '/^$/d' | wc -l | tr -d '[:space:]')
shown_limit="${FM_UPSTREAM_AUTOSYNC_OVERLAP_SHOWN:-20}"
case "$shown_limit" in ''|*[!0-9]*) shown_limit=20 ;; esac
if [ -z "$overlap" ]; then
  overlap_shown=""
else
  overlap_shown=$(printf '%s\n' "$overlap" | sed '/^$/d' | head -n "$shown_limit")
fi

# --- eligibility --------------------------------------------------------
commit_threshold="${FM_UPSTREAM_AUTOSYNC_COMMIT_THRESHOLD:-5}"
case "$commit_threshold" in ''|*[!0-9]*) commit_threshold=5 ;; esac
days_threshold="${FM_UPSTREAM_AUTOSYNC_DAYS_THRESHOLD:-14}"
case "$days_threshold" in ''|*[!0-9]*) days_threshold=14 ;; esac

config_gate="$FM_HOME/config/upstream-autosync"
eligible=no
eligible_reason="config/upstream-autosync is absent, so auto-dispatch stays off (ask-only)"
if [ -f "$config_gate" ]; then
  if [ "$behind" -ge "$commit_threshold" ]; then
    eligible=yes
    eligible_reason="behind ($behind) >= commit threshold ($commit_threshold)"
  elif [ "$days_behind" != unknown ] && [ "$days_behind" -ge "$days_threshold" ]; then
    eligible=yes
    eligible_reason="days behind ($days_behind) >= days threshold ($days_threshold)"
  else
    if [ "$days_behind" = unknown ]; then
      eligible_reason="behind ($behind) is below the commit threshold ($commit_threshold) and the newest upstream commit date could not be determined, so the $days_threshold-day rule could not be evaluated"
    else
      eligible_reason="behind ($behind) and days behind ($days_behind) are below threshold ($commit_threshold commits / $days_threshold days)"
    fi
  fi
fi

# --- compose the backlog note ------------------------------------------
note_body() {
  if [ "$days_behind" = unknown ]; then
    printf 'Upstream sync: %s commits behind upstream/%s (age of the newest upstream commit is unknown).\n' \
      "$behind" "$default"
  else
    printf 'Upstream sync: %s commits behind upstream/%s (%s days since newest upstream commit).\n' \
      "$behind" "$default" "$days_behind"
  fi
  printf 'Auto-dispatch eligible: %s (%s)\n' "$eligible" "$eligible_reason"
  printf 'Files touched both upstream and locally since merge-base (conflict risk): %s\n' "$overlap_count"
  if [ -n "$overlap_shown" ]; then
    printf '%s\n' "$overlap_shown" | sed 's/^/  - /'
  fi
  printf 'Pending upstream commits (%s..upstream/%s):\n' "$default" "$default"
  printf '%s\n' "$log_delta"
}

title="Upstream sync ($behind commits behind)"
action=filed
if fm_tasks_axi_backend_available "$FM_HOME/config"; then
  # `tasks-axi show <id>` is the existence probe: it exits non-zero with
  # NOT_FOUND for an unknown id and covers every state, so the one stable id
  # is refreshed rather than re-filed no matter which column it currently
  # sits in. The body is the only channel the eligibility signal survives on,
  # so a failed write is an error here, not a silent no-op.
  body_file=$(mktemp "${TMPDIR:-/tmp}/fm-upstream-sync-body.XXXXXX") || exit 1
  trap 'rm -f "$body_file"' EXIT
  note_body > "$body_file"
  if item_shown=$(cd "$FM_HOME" && tasks-axi show "$ITEM_ID" 2>/dev/null); then
    action=refreshed
    # A closed item must come back to Queued or the refreshed payload is not
    # dispatchable; a queued item needs nothing and an in_flight item must be
    # left alone, because reopen would pull back a crewmate's active work.
    item_state=$(printf '%s\n' "$item_shown" | sed -n 's/^[[:space:]]*state:[[:space:]]*//p' | head -n 1)
    case "$item_state" in
      done|closed)
        (cd "$FM_HOME" && tasks-axi reopen "$ITEM_ID" >/dev/null) \
          || { echo "error: tasks-axi reopen $ITEM_ID failed; the refreshed sync item is not dispatchable" >&2; exit 1; }
        ;;
    esac
    (cd "$FM_HOME" && tasks-axi update "$ITEM_ID" --title "$title" \
      --kind "$ITEM_KIND" --repo "$ITEM_REPO" \
      --body-file "$body_file" --archive-body >/dev/null) \
      || { echo "error: tasks-axi update $ITEM_ID failed; the sync item carries no eligibility signal" >&2; exit 1; }
  else
    (cd "$FM_HOME" && tasks-axi add "$ITEM_ID" "$title" \
      --kind "$ITEM_KIND" --repo "$ITEM_REPO" --body-file "$body_file" >/dev/null) \
      || { echo "error: tasks-axi add $ITEM_ID failed" >&2; exit 1; }
  fi
else
  # data/backlog.md is a whole-file replace here. The reserved `backlog` lease
  # is READ here only: it is actor-scoped and outlives any single process, so
  # this unattended script must never claim or release it - a same-actor claim
  # would refresh, and the release would drop, a lease the supervising session
  # still holds. Concurrency between unattended writers is handled by the
  # repo's process-scoped lock instead. The tasks-axi path above needs neither,
  # because tasks-axi owns its own locks.
  mkdir -p "$(dirname "$BACKLOG_MD")" 2>/dev/null || true
  mkdir -p "$STATE" 2>/dev/null || true
  [ -f "$BACKLOG_MD" ] || : > "$BACKLOG_MD"
  self_actor=$(fm_lease_actor 2>/dev/null) || self_actor=main
  if fm_lease_live backlog && [ "$FM_LEASE_ACTOR" != "$self_actor" ]; then
    echo "warning: the backlog lease is held by the $FM_LEASE_ACTOR supervision actor; skipping the sync item write this episode" >&2
    action=skipped
  else
    fm_lock_acquire_wait "$BACKLOG_WRITE_LOCK"
    trap 'fm_lock_release "$BACKLOG_WRITE_LOCK"' EXIT
    block=$(printf '%s\n### %s\n%s\n%s\n' "$MARK_START" "$ITEM_ID" "$(note_body)" "$MARK_END")
    tmp=$(mktemp "$BACKLOG_MD.XXXXXX")
    # awk is the single matcher for the marker pair, so detection and rewrite
    # can never disagree: it reports substituted (0), no block present (2), or
    # an unterminated block (1), and a lost end marker must not swallow every
    # item after the block. data/backlog.md is hand-edited, so the markers are
    # matched with surrounding whitespace trimmed. The block travels through
    # the environment: awk -v expands backslash escapes, which would mangle an
    # upstream commit subject.
    FM_SYNC_BLOCK="$block" awk -v start="$MARK_START" -v end="$MARK_END" '
      function trim(l) { gsub(/^[ \t]+|[ \t]+$/, "", l); return l }
      trim($0) == start { if (!found) print ENVIRON["FM_SYNC_BLOCK"]; found=1; skip=1; next }
      trim($0) == end { if (skip) { skip=0; next } }
      skip { next }
      { print }
      END { exit (skip ? 1 : (found ? 0 : 2)) }
    ' "$BACKLOG_MD" > "$tmp"
    rewrite_rc=$?
    case "$rewrite_rc" in
      0)
        action=refreshed
        mv -f "$tmp" "$BACKLOG_MD"
        ;;
      2)
        rm -f "$tmp"
        { printf '\n'; printf '%s\n' "$block"; } >> "$BACKLOG_MD"
        ;;
      *)
        rm -f "$tmp"
        echo "error: $BACKLOG_MD has an unterminated $MARK_START block; leaving it untouched" >&2
        action=skipped
        ;;
    esac
  fi
fi

printf 'item_id=%s\n' "$ITEM_ID"
printf 'action=%s\n' "$action"
printf 'behind=%s\n' "$behind"
printf 'days_behind=%s\n' "$days_behind"
printf 'eligible=%s\n' "$eligible"
printf 'eligible_reason=%s\n' "$eligible_reason"
printf 'overlap_count=%s\n' "$overlap_count"
if [ -n "$overlap_shown" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf 'overlap=%s\n' "$f"
  done <<< "$overlap_shown"
fi
exit 0
