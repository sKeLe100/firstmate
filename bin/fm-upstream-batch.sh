#!/usr/bin/env bash
# fm-upstream-batch.sh - plan the next BOUNDED upstream sync batch: the exact
# upstream commit a sync task may merge up to, never further.
#
# WHY A BOUND. An unbounded sync merges every commit upstream has landed since
# the fork last synced. Left alone for a few weeks on a busy upstream that is
# well over a hundred commits, and the merge becomes hours of conflict triage
# across dozens of files in one sitting. This script cuts the pending upstream
# delta into the next batch of at most FM_UPSTREAM_AUTOSYNC_BATCH_MAX commits
# (default BATCH_MAX_DEFAULT below, 20) so each sync task keeps a small conflict
# surface, and a periodic dispatch (docs/configuration.md "Upstream autosync")
# drains the gap a batch at a time instead of all at once.
#
# BATCH BOUNDARY. The batch is the oldest first-parent commits of
# refs/remotes/upstream/<default> past the merge-base with refs/heads/<default>,
# in history order, and the target is the newest of them. Cutting on upstream's
# first-parent line keeps a batch at a natural boundary: an upstream that lands
# PRs as merge commits is cut between PRs, never inside one, and a linear
# upstream is cut between commits. `behind` counts every pending commit while
# batch_count counts first-parent steps, so the two differ exactly when a PR
# merge carries side commits; batch_remaining is the number of first-parent
# steps still pending after the target.
#
# TRUE MERGE ONLY. The bound is the commit a sync task merges with a true
# merge (`git merge --no-ff <batch_target>`); it is never a rebase target.
# Rebasing the fork's own default branch onto upstream rewrites the fork's
# history and replays every fork commit through every upstream change, which is
# exactly the needless conflict surface this bound exists to avoid.
# bin/fm-brief.sh --upstream-sync turns this plan into the worker's bounded
# batch gate; this script only computes it.
#
# READ-ONLY, NO NETWORK. It reads refs the drift check already fetched
# (bin/fm-upstream-behind-check.sh owns the fetch and its cadence) and never
# fetches, merges, rebases, resets, or writes anything.
#
# Usage:
#   fm-upstream-batch.sh plan [--max <N>] [--default <branch>]
#     Prints one `key=value` per line:
#       status=ok
#       default=<branch>
#       merge_base=<sha>
#       behind=<N>                  (every pending upstream commit)
#       batch_max=<N>
#       batch_target=<sha>          (merge exactly this, never beyond)
#       batch_count=<N>             (first-parent steps merge_base..batch_target)
#       batch_remaining=<N>         (first-parent steps still pending after it)
#       batch_oldest_date=<YYYY-MM-DD>
#       batch_newest_date=<YYYY-MM-DD>
#       batch_log_hint=<git log command listing exactly this batch>
#     or, when no batch can be planned:
#       status=unknown
#       reason=<no-upstream-remote|no-default-branch|no-upstream-ref|no-merge-base|up-to-date>
#     Exit status is 0 in both cases; only a usage error exits non-zero, so a
#     caller reads `status=` rather than the exit code.
#
# FM_UPSTREAM_AUTOSYNC_BATCH_MAX overrides the default bound; --max wins over it.
# FM_ROOT_OVERRIDE points the plan at another checkout (tests use it).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

BATCH_MAX_DEFAULT=20

usage() {
  sed -n '2,/^set -u/p' "$SCRIPT_DIR/fm-upstream-batch.sh" | sed -n 's/^# \{0,1\}//p'
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

[ "${1:-}" = plan ] || { usage >&2; exit 1; }
shift

batch_max="${FM_UPSTREAM_AUTOSYNC_BATCH_MAX:-$BATCH_MAX_DEFAULT}"
default=
while [ $# -gt 0 ]; do
  case "$1" in
    --max)
      [ $# -ge 2 ] || { echo "error: --max needs a value" >&2; exit 1; }
      batch_max=$2
      shift 2
      ;;
    --default)
      [ $# -ge 2 ] || { echo "error: --default needs a value" >&2; exit 1; }
      default=$2
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done
case "$batch_max" in ''|*[!0-9]*|0) batch_max=$BATCH_MAX_DEFAULT ;; esac

unknown() {  # <reason>
  printf 'status=unknown\n'
  printf 'reason=%s\n' "$1"
  exit 0
}

git -C "$FM_ROOT" remote get-url upstream >/dev/null 2>&1 || unknown no-upstream-remote
if [ -z "$default" ]; then
  default=$(default_branch "$FM_ROOT" 2>/dev/null) || unknown no-default-branch
fi
local_ref="refs/heads/$default"
upstream_ref="refs/remotes/upstream/$default"
git -C "$FM_ROOT" show-ref --verify --quiet "$local_ref" || unknown no-default-branch
git -C "$FM_ROOT" show-ref --verify --quiet "$upstream_ref" || unknown no-upstream-ref
merge_base=$(git -C "$FM_ROOT" merge-base "$local_ref" "$upstream_ref" 2>/dev/null) || merge_base=
[ -n "$merge_base" ] || unknown no-merge-base

behind=$(git -C "$FM_ROOT" rev-list --count "$merge_base..$upstream_ref" 2>/dev/null) || behind=0
case "$behind" in ''|*[!0-9]*) behind=0 ;; esac
[ "$behind" -gt 0 ] || unknown up-to-date

# Oldest first, so the first N lines are the next batch in history order.
first_parent=$(git -C "$FM_ROOT" rev-list --first-parent --reverse "$merge_base..$upstream_ref" 2>/dev/null)
[ -n "$first_parent" ] || unknown no-merge-base
total_steps=$(printf '%s\n' "$first_parent" | sed '/^$/d' | wc -l | tr -d '[:space:]')
batch_count=$total_steps
[ "$batch_count" -le "$batch_max" ] || batch_count=$batch_max
batch_target=$(printf '%s\n' "$first_parent" | sed -n "${batch_count}p")
batch_remaining=$(( total_steps - batch_count ))

oldest_sha=$(printf '%s\n' "$first_parent" | sed -n '1p')
batch_oldest_date=$(git -C "$FM_ROOT" log -1 --format=%cd --date=short "$oldest_sha" 2>/dev/null) || batch_oldest_date=
batch_newest_date=$(git -C "$FM_ROOT" log -1 --format=%cd --date=short "$batch_target" 2>/dev/null) || batch_newest_date=

printf 'status=ok\n'
printf 'default=%s\n' "$default"
printf 'merge_base=%s\n' "$merge_base"
printf 'behind=%s\n' "$behind"
printf 'batch_max=%s\n' "$batch_max"
printf 'batch_target=%s\n' "$batch_target"
printf 'batch_count=%s\n' "$batch_count"
printf 'batch_remaining=%s\n' "$batch_remaining"
printf 'batch_oldest_date=%s\n' "$batch_oldest_date"
printf 'batch_newest_date=%s\n' "$batch_newest_date"
printf 'batch_log_hint=git log --oneline --first-parent %s..%s\n' "$merge_base" "$batch_target"
exit 0
