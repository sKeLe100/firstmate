#!/usr/bin/env bash
# fm-upstream-behind-check.sh - read-only daily check of this home's tracked
# code root against its configured `upstream` git remote.
#
# WHY THIS IS SEPARATE FROM SELF-UPDATE. bin/fm-update.sh and the
# /updatefirstmate skill are fast-forward-only against `origin`, on purpose,
# and never look at `upstream` (AGENTS.md section 12 owns that contract; this
# script does not change it). A home's `origin` can be an independent repo
# that has diverged from `upstream` in both directions, so a fast-forward from
# `upstream` is not always even possible. This script answers a different,
# purely informational question - "how far has this home's default branch
# diverged from upstream, both ways?" - and never merges, rebases, resets,
# fast-forwards, or pushes anything. The only mutation it performs is fetching
# `upstream`'s remote-tracking refs, which touches no local branch and no
# working tree.
#
# ONCE DAILY. A normal invocation is a cheap no-op - it just re-prints the
# cached report - unless the last completed check is more than 24h old
# (FM_UPSTREAM_CHECK_INTERVAL overrides the interval, in seconds, for tests).
# Pass --force to bypass the gate and check now regardless of age.
#
# DEGRADES QUIETLY. A missing `upstream` remote, a missing default branch on
# either side, or an unreachable network is reported as status=unknown with a
# reason, never a non-zero exit or a captain-facing error.
#
# Usage: fm-upstream-behind-check.sh [--force]
#
# A bare behind/ahead count does not say WHAT changed, and skill changes are
# what the captain most wants visibility on, so an ok result also groups the
# pending upstream commits' changed files by area (.agents/skills, bin, docs,
# tests, other - file counts only, never full paths) and lists the changed
# skill names explicitly. The skill list is bounded (FM_UPSTREAM_SKILLS_SHOWN,
# default 12; alphabetical; skills_total/skills_shown disclose how many were
# cut) and a detail_hint line names the exact bounded `git log` command for the
# full commit list, so the report itself never grows into a raw commit dump.
#
# Output: multiple `key=value` lines on stdout, one per field, published
# atomically to $FM_HOME/state/.upstream-behind-check.report (gitignored, per
# AGENTS.md section 2 - a volatile per-run marker, not tracked material):
#   status=ok
#   behind=<N>
#   ahead=<N>
#   newest_upstream_date=<YYYY-MM-DD>
#   area_count_agents_skills=<N>   (changed-file count per area, only when > 0)
#   area_count_bin=<N>
#   area_count_docs=<N>
#   area_count_tests=<N>
#   area_count_other=<N>
#   skill=<name>                   (one line per changed skill, bounded, sorted)
#   skills_total=<N>
#   skills_shown=<N>
#   detail_hint=<git log command for the full pending commit list>
#   checked_at=<epoch>
# or, degrading quietly:
#   status=unknown
#   reason=<no-upstream-remote|no-default-branch|unreachable>
#   checked_at=<epoch>
#
# bin/fm-bearings-snapshot.sh reads that cached report file directly (a local
# read, no network) to surface it in the morning debrief; it never invokes
# this script itself, keeping its own LOCAL-ONLY-by-default contract intact.
#
# FM_UPSTREAM_CHECK_TIMEOUT bounds the fetch itself (default 20s).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REPORT_FILE="$STATE/.upstream-behind-check.report"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# fm-ff-lib.sh's default_branch() is the one owner of "which branch is this
# repo's default", already used by the self-update fast-forward; reused here
# read-only, never through any of that library's mutating helpers.
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

usage() {
  sed -n '2,63p' "$SCRIPT_DIR/fm-upstream-behind-check.sh" | sed 's/^# \{0,1\}//'
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

force=0
if [ "${1:-}" = "--force" ]; then
  force=1
  shift
fi
[ $# -eq 0 ] || { usage >&2; exit 1; }

now() { date +%s; }

write_atomic() {  # <dest>, content on stdin
  local dest=$1 tmp
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  tmp=$(mktemp "$dest.XXXXXX" 2>/dev/null) || return 1
  if cat >"$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

report_field() {  # <key>
  [ -f "$REPORT_FILE" ] || return 0
  sed -n "s/^$1=//p" "$REPORT_FILE" | tail -1
}

interval="${FM_UPSTREAM_CHECK_INTERVAL:-86400}"
case "$interval" in ''|*[!0-9]*) interval=86400 ;; esac

if [ "$force" -ne 1 ] && [ -f "$REPORT_FILE" ]; then
  last=$(report_field checked_at)
  case "$last" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$(( $(now) - last ))" -lt "$interval" ]; then
        cat "$REPORT_FILE"
        exit 0
      fi
      ;;
  esac
fi

publish() {  # <status> [key=value...] - one line per field, newline-joined.
  local status=$1 block
  shift
  block="status=$status"
  for kv in "$@"; do block="$block
$kv"; done
  block="$block
checked_at=$(now)"
  printf '%s\n' "$block" | write_atomic "$REPORT_FILE" || true
  printf '%s\n' "$block"
}

if ! git -C "$FM_ROOT" remote get-url upstream >/dev/null 2>&1; then
  publish unknown "reason=no-upstream-remote"
  exit 0
fi

default=$(default_branch "$FM_ROOT") || {
  publish unknown "reason=no-default-branch"
  exit 0
}

timeout="${FM_UPSTREAM_CHECK_TIMEOUT:-20}"
case "$timeout" in ''|*[!0-9]*|0) timeout=20 ;; esac

if ! fm_run_timed "$timeout" git -C "$FM_ROOT" fetch --quiet --no-tags upstream "$default" >/dev/null 2>&1; then
  # A fetch failure is ambiguous: the remote may be unreachable, or reachable
  # but simply missing this branch (the default branch is resolved from
  # *origin*'s HEAD, which need not match upstream's). Probe the ref itself so
  # each degrade case gets its own honest reason.
  if fm_run_timed "$timeout" git -C "$FM_ROOT" ls-remote --quiet --exit-code upstream "refs/heads/$default" >/dev/null 2>&1; then
    publish unknown "reason=unreachable"
  elif fm_run_timed "$timeout" git -C "$FM_ROOT" ls-remote --quiet upstream >/dev/null 2>&1; then
    publish unknown "reason=no-default-branch"
  else
    publish unknown "reason=unreachable"
  fi
  exit 0
fi

if ! git -C "$FM_ROOT" show-ref --verify --quiet "refs/remotes/upstream/$default" \
  || ! git -C "$FM_ROOT" show-ref --verify --quiet "refs/heads/$default"; then
  publish unknown "reason=no-default-branch"
  exit 0
fi

counts=$(git -C "$FM_ROOT" rev-list --left-right --count \
  "refs/remotes/upstream/$default...refs/heads/$default" 2>/dev/null) || counts=
if [ -z "$counts" ]; then
  publish unknown "reason=unreachable"
  exit 0
fi
behind=${counts%%$'\t'*}
ahead=${counts##*$'\t'}
newest=$(git -C "$FM_ROOT" log -1 --format=%cd --date=short "refs/remotes/upstream/$default" 2>/dev/null)
[ -n "$newest" ] || newest=unknown

# Drift summary: what changed upstream since it diverged from this branch,
# grouped by area with a bounded, sorted skill-name list - never the raw
# per-commit log. Three-dot diff compares the upstream tip against the
# merge-base, so it names only content pending from upstream, regardless of
# this branch's own unrelated local commits.
fields=("behind=$behind" "ahead=$ahead" "newest_upstream_date=$newest")
if [ "$behind" -gt 0 ]; then
  area_agents_skills=0 area_bin=0 area_docs=0 area_tests=0 area_other=0
  skills_list=""
  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    case "$changed_file" in
      .agents/skills/*)
        area_agents_skills=$((area_agents_skills + 1))
        skill_name=${changed_file#.agents/skills/}
        skill_name=${skill_name%%/*}
        case " $skills_list " in
          *" $skill_name "*) : ;;
          *) skills_list="$skills_list $skill_name" ;;
        esac
        ;;
      bin/*) area_bin=$((area_bin + 1)) ;;
      docs/*) area_docs=$((area_docs + 1)) ;;
      tests/*) area_tests=$((area_tests + 1)) ;;
      *) area_other=$((area_other + 1)) ;;
    esac
  done < <(git -C "$FM_ROOT" diff --name-only \
    "refs/heads/$default...refs/remotes/upstream/$default" 2>/dev/null)

  [ "$area_agents_skills" -eq 0 ] || fields+=("area_count_agents_skills=$area_agents_skills")
  [ "$area_bin" -eq 0 ] || fields+=("area_count_bin=$area_bin")
  [ "$area_docs" -eq 0 ] || fields+=("area_count_docs=$area_docs")
  [ "$area_tests" -eq 0 ] || fields+=("area_count_tests=$area_tests")
  [ "$area_other" -eq 0 ] || fields+=("area_count_other=$area_other")

  if [ -n "$skills_list" ]; then
    # shellcheck disable=SC2086 # word-splitting the accumulated list is intended
    sorted_skills=$(printf '%s\n' $skills_list | sort -u)
    skills_total=$(printf '%s\n' "$sorted_skills" | sed '/^$/d' | wc -l | tr -d '[:space:]')
    shown_limit="${FM_UPSTREAM_SKILLS_SHOWN:-12}"
    case "$shown_limit" in ''|*[!0-9]*) shown_limit=12 ;; esac
    shown_skills=$(printf '%s\n' "$sorted_skills" | sed '/^$/d' | head -n "$shown_limit")
    skills_shown=$(printf '%s\n' "$shown_skills" | sed '/^$/d' | wc -l | tr -d '[:space:]')
    while IFS= read -r one_skill; do
      [ -n "$one_skill" ] || continue
      fields+=("skill=$one_skill")
    done <<< "$shown_skills"
    fields+=("skills_total=$skills_total" "skills_shown=$skills_shown")
  fi

  fields+=("detail_hint=git -C $FM_ROOT log --oneline refs/heads/$default..refs/remotes/upstream/$default")
fi

publish ok "${fields[@]}"
