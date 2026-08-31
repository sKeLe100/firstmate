#!/usr/bin/env bash
# fm-upstream-sync-item.sh - file-or-refresh the ONE stable-id upstream sync
# backlog item for an open drift episode, and report auto-dispatch eligibility.
#
# Called by bin/fm-upstream-behind-check.sh's `check` action whenever an
# upstream drift episode is open (AGENTS.md section 7 "Intake and authority";
# docs/configuration.md "Upstream autosync"). This script never spawns a
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
#       action=filed|refreshed
#       behind=<N>
#       days_behind=<N>
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

ITEM_ID=upstream-sync
BACKLOG_MD="$FM_HOME/data/backlog.md"
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
days_behind=0
if [ -n "$newest" ] && [ "$newest" != unknown ]; then
  now_epoch=$(date +%s)
  newest_epoch=$(date -d "$newest" +%s 2>/dev/null) || newest_epoch=
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
overlap_shown=$([ -z "$overlap" ] && echo "" || printf '%s\n' "$overlap" | sed '/^$/d' | head -n "$shown_limit")

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
  elif [ "$days_behind" -ge "$days_threshold" ]; then
    eligible=yes
    eligible_reason="days behind ($days_behind) >= days threshold ($days_threshold)"
  else
    eligible_reason="behind ($behind) and days behind ($days_behind) are below threshold ($commit_threshold commits / $days_threshold days)"
  fi
fi

# --- compose the backlog note ------------------------------------------
note_body() {
  printf 'Upstream sync: %s commits behind upstream/%s (%s days since newest upstream commit).\n' \
    "$behind" "$default" "$days_behind"
  printf 'Auto-dispatch eligible: %s (%s)\n' "$eligible" "$eligible_reason"
  printf 'Files touched both upstream and locally since merge-base (conflict risk): %s\n' "$overlap_count"
  if [ -n "$overlap_shown" ]; then
    printf '%s\n' "$overlap_shown" | sed 's/^/  - /'
  fi
  printf 'Pending commits (upstream/%s..this branch reversed):\n' "$default"
  printf '%s\n' "$log_delta"
}

action=filed
if fm_tasks_axi_backend_available "$FM_HOME/config"; then
  if (cd "$FM_HOME" && tasks-axi list --state queued --fields id 2>/dev/null | grep -qx "$ITEM_ID") \
    || (cd "$FM_HOME" && tasks-axi list --state held --fields id 2>/dev/null | grep -qx "$ITEM_ID") \
    || (cd "$FM_HOME" && tasks-axi list --state in_flight --fields id 2>/dev/null | grep -qx "$ITEM_ID"); then
    action=refreshed
    note_body | (cd "$FM_HOME" && tasks-axi update "$ITEM_ID" --note-file - >/dev/null 2>&1) \
      || note_body | (cd "$FM_HOME" && tasks-axi update "$ITEM_ID" --note - >/dev/null 2>&1) || true
  else
    (cd "$FM_HOME" && tasks-axi add "$ITEM_ID" --title "Upstream sync ($behind commits behind)" >/dev/null 2>&1) || true
    note_body | (cd "$FM_HOME" && tasks-axi update "$ITEM_ID" --note-file - >/dev/null 2>&1) \
      || note_body | (cd "$FM_HOME" && tasks-axi update "$ITEM_ID" --note - >/dev/null 2>&1) || true
  fi
else
  mkdir -p "$(dirname "$BACKLOG_MD")" 2>/dev/null || true
  [ -f "$BACKLOG_MD" ] || : > "$BACKLOG_MD"
  block=$(printf '%s\n### %s\n%s\n%s\n' "$MARK_START" "$ITEM_ID" "$(note_body)" "$MARK_END")
  if grep -qF "$MARK_START" "$BACKLOG_MD" 2>/dev/null; then
    action=refreshed
    tmp=$(mktemp "$BACKLOG_MD.XXXXXX")
    awk -v start="$MARK_START" -v end="$MARK_END" -v block="$block" '
      $0 == start { print block; skip=1; next }
      $0 == end { if (skip) { skip=0; next } }
      skip { next }
      { print }
    ' "$BACKLOG_MD" > "$tmp" && mv -f "$tmp" "$BACKLOG_MD" || rm -f "$tmp"
  else
    { printf '\n'; printf '%s\n' "$block"; } >> "$BACKLOG_MD"
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
