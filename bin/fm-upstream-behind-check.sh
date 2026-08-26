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
# Usage:
#   fm-upstream-behind-check.sh [--force]   refresh-or-print the cached report
#   fm-upstream-behind-check.sh check       actionable drift poll (silent unless news)
#   fm-upstream-behind-check.sh arm         write and register state/upstream-drift.check.sh
#   fm-upstream-behind-check.sh disarm      remove the drift shim, binding, and record
#
# ACTIONABLE DRIFT TRIGGER. The cached report above is passive: it is only seen
# when someone reads the morning debrief, so a fork can drift for weeks while
# every session sees the number and no session acts on it. `check` turns the
# same daily refresh into one durable actionable signal. It drives a refresh
# (the once-daily gate above still applies, so the watcher's own cadence costs
# nothing extra in between), then prints one line naming the gap and asking for
# an upstream sync task when the refresh reports the fork at least
# FM_UPSTREAM_DRIFT_THRESHOLD commits behind (default DRIFT_THRESHOLD_DEFAULT
# below, 25). It prints nothing at all otherwise, so it composes with the
# existing watcher state-check contract rather than needing a schedule of its
# own; `arm` writes state/upstream-drift.check.sh and binds its bytes with
# fm-check-register.sh so the watcher turns that one line into a `check:` wake.
#
# ONE REPORT PER THRESHOLD-SIZED BLOCK OF DRIFT. A gap that stays open is not
# news every day. The report record state/.upstream-drift holds the behind
# count the last report was made from (reported_behind), so the trigger fires
# once when the gap first crosses the threshold and then stays silent until
# another full threshold of genuinely NEW upstream work has accumulated -
# `behind - reported_behind >= threshold` - at which point it fires again and
# re-baselines the record to the current count. Baselining on new drift rather
# than only on the absolute count is what keeps this reachable on a fork that
# lands its syncs as squash merges: `behind` is a hash-reachability count, so
# replayed upstream content never brings it back down, and a reset keyed purely
# on `behind < threshold` would latch the trigger silent forever after one
# firing. That clear-on-gap-closed path is still kept - it is correct and does
# fire when a sync lands as a true merge - it is simply no longer the only way
# back to reporting. Only an `ok` refresh moves episode state - a degraded
# (status=unknown) refresh neither fires nor clears, so going offline
# mid-episode cannot manufacture a repeat report when the network returns.
#
# The refresh runs as a bounded child rather than inline, so the proven
# degrade-and-publish path above stays byte-for-byte the path a plain
# invocation takes, and `check` only reads the report it leaves behind. That
# child's two worst-case network bounds have to fit inside the watcher's own
# per-check bound, because a run the watcher kills prints nothing and writes no
# record: a configured FM_UPSTREAM_CHECK_TIMEOUT larger than FM_CHECK_TIMEOUT
# (default 30, read from this check's own environment because the watcher runs
# it as a direct child) allows is cut down to what fits, never raised - all the
# way down to no probe at all. When the watcher's bound leaves room for no
# usable network bound, the child skips the probe entirely and still publishes a
# degraded report (reason=timeout-budget), so checked_at is stamped and the
# once-daily gate is honored, instead of the run being killed mid-probe having
# written nothing.
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
#   reason=<no-upstream-remote|no-default-branch|unreachable|timeout-budget>
#   stale_behind=<N>               (last known ok result, when there was one)
#   stale_ahead=<N>
#   stale_newest_upstream_date=<YYYY-MM-DD>
#   stale_checked_at=<epoch>
#   checked_at=<epoch>
#
# A degrade never blanks a last-known-good result: it carries the previous ok
# report's counts forward as stale_* fields, and while that result is still
# inside its own gate window it keeps that result's checked_at as the gate
# stamp, so a transient outage neither erases the digest's drift summary nor
# burns the retry. Once the good result has itself aged past the interval the
# degrade stamps the current time again, so a sustained outage still does real
# work at most once per interval rather than on every invocation.
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
  sed -n '2,/^[^#]/p' "$SCRIPT_DIR/fm-upstream-behind-check.sh" \
    | sed -n 's/^# \{0,1\}//p'
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

# --- actionable drift trigger ------------------------------------------------
#
# The threshold is a constant so the shipped behavior is one reviewable number,
# with FM_UPSTREAM_DRIFT_THRESHOLD as the local override (tests use it too).
DRIFT_THRESHOLD_DEFAULT=25
DRIFT_CHECK_ID=upstream-drift
DRIFT_RECORD="$STATE/.upstream-drift"
DRIFT_CHECK_SHIM="$STATE/$DRIFT_CHECK_ID.check.sh"
DRIFT_CHECK_TRUST="$STATE/$DRIFT_CHECK_ID.check-trust"
DRIFT_REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
DRIFT_RECORD_SCHEMA=fm-upstream-drift-v1
# Wider than the digest default because the line carries the counts, the
# threshold, and the exact command that lists the pending commits.
DRIFT_MAX_LINE=1000

drift_threshold() {
  local want=${FM_UPSTREAM_DRIFT_THRESHOLD:-$DRIFT_THRESHOLD_DEFAULT}
  case "$want" in
    ''|*[!0-9]*|0) want=$DRIFT_THRESHOLD_DEFAULT ;;
  esac
  printf '%s\n' "$want"
}

# The refresh child inherits every FM_UPSTREAM_* setting except its fetch bound,
# which is cut - never raised - to leave both worst-case network probes inside
# the watcher's own per-check timeout.
drift_refresh_timeout() {
  local want check_timeout fits
  want="${FM_UPSTREAM_CHECK_TIMEOUT:-20}"
  case "$want" in ''|*[!0-9]*|0) want=20 ;; esac
  check_timeout="${FM_CHECK_TIMEOUT:-30}"
  case "$check_timeout" in ''|*[!0-9]*|0) check_timeout=30 ;; esac
  fits=$(( (check_timeout - 2) / 2 ))
  # Never raised: a bound below 1s is not a shorter probe, it is no probe, and
  # the caller skips the network entirely rather than being killed mid-fetch.
  [ "$fits" -ge 1 ] || fits=0
  [ "$want" -le "$fits" ] || want=$fits
  printf '%s\n' "$want"
}

# Episode state: the behind count the open episode was reported from, or absent
# when no episode is open. A record whose schema line does not match is treated
# as absent, so a format change re-reports once instead of staying silent.
DRIFT_REPORTED_BEHIND=

drift_record_read() {
  local line first=1
  DRIFT_REPORTED_BEHIND=
  [ -f "$DRIFT_RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$DRIFT_RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      reported_behind=*)
        line=${line#reported_behind=}
        case "$line" in
          ''|*[!0-9]*) ;;
          *) DRIFT_REPORTED_BEHIND=$line ;;
        esac
        ;;
    esac
  done < "$DRIFT_RECORD"
  return 0
}

drift_record_write() {  # <behind>
  local tmp
  mkdir -p "$STATE" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "$DRIFT_RECORD.XXXXXX" 2>/dev/null) || return 1
  {
    printf '%s\n' "$DRIFT_RECORD_SCHEMA"
    printf 'reported_behind=%s\n' "$1"
    printf 'reported_at=%s\n' "$(now)"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$DRIFT_RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

action_check() {
  local threshold behind status detail line refresh_timeout
  threshold=$(drift_threshold)

  # Discarded output: a plain refresh prints the whole report, and this check
  # may print only its own one line, or nothing.
  refresh_timeout=$(drift_refresh_timeout)
  if [ "$refresh_timeout" -eq 0 ]; then
    FM_UPSTREAM_NO_PROBE=1 \
      "$SCRIPT_DIR/fm-upstream-behind-check.sh" >/dev/null 2>&1 || true
  else
    FM_UPSTREAM_CHECK_TIMEOUT="$refresh_timeout" \
      "$SCRIPT_DIR/fm-upstream-behind-check.sh" >/dev/null 2>&1 || true
  fi

  status=$(report_field status)
  # A degrade neither fires nor closes an open episode: an unknown carries no
  # current count, so acting on it would either invent news or forget it.
  [ "$status" = ok ] || return 0
  behind=$(report_field behind)
  case "$behind" in ''|*[!0-9]*) return 0 ;; esac

  drift_record_read

  if [ "$behind" -lt "$threshold" ]; then
    # The gap closed, so the episode ends here and the next one is news again.
    rm -f -- "$DRIFT_RECORD" 2>/dev/null || true
    return 0
  fi

  # An open episode stays silent until another full threshold of new upstream
  # work has landed; each firing re-baselines, so one report covers one
  # threshold-sized block of drift.
  if [ -n "$DRIFT_REPORTED_BEHIND" ]; then
    [ "$(( behind - DRIFT_REPORTED_BEHIND ))" -ge "$threshold" ] || return 0
  fi

  detail=$(report_field detail_hint)
  line="upstream drift: this home is $behind commits behind upstream (threshold $threshold) - dispatch an upstream sync task"
  [ -z "$detail" ] || line="$line; pending commits: $detail"
  fm_cap_line_var "$line" "$DRIFT_MAX_LINE"
  # Report before recording, so a record that cannot be written costs a repeated
  # report rather than a lost one.
  printf '%s\n' "$FM_LINE_CAP_LINE"
  drift_record_write "$behind" || true
  return 0
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
drift_shim_content() {  # <home>
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-upstream-behind-check.sh - upstream drift poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-upstream-behind-check.sh") check"
}

# Written the way this repo writes its other trusted check shims: the guards run
# before anything is written, so a symlink at the shim path is refused instead
# of followed, and the bytes arrive by rename so the watcher never reads a
# half-written shim and rejects it as unauthenticated.
DRIFT_SHIM_WRITE_TMP=

drift_shim_write() {  # <wanted-bytes>
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$DRIFT_CHECK_SHIM" "$device" || return 1
  if [ -e "$DRIFT_CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$DRIFT_CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$DRIFT_CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-upstream-drift-check.XXXXXX" 2>/dev/null) || return 1
  DRIFT_SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    DRIFT_SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$DRIFT_CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$DRIFT_CHECK_SHIM"; then
    rm -f -- "$tmp"
    DRIFT_SHIM_WRITE_TMP=
    return 1
  fi
  DRIFT_SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$DRIFT_CHECK_SHIM" 700 "$device"
}

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So a failed or
# interrupted arm never leaves a shim without a matching trust binding.
drift_arm_rollback() {
  [ -z "$DRIFT_SHIM_WRITE_TMP" ] || rm -f -- "$DRIFT_SHIM_WRITE_TMP"
  DRIFT_SHIM_WRITE_TMP=
  rm -f -- "$DRIFT_CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
drift_arm_interrupted() {
  drift_arm_rollback
  printf 'fm-upstream-behind-check: arming was interrupted, so state/%s.check.sh is not armed\n' \
    "$DRIFT_CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-upstream-behind-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(drift_shim_content "$home")
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap drift_arm_interrupted HUP INT TERM
  if ! drift_shim_write "$want"; then
    trap - HUP INT TERM
    drift_arm_rollback
    printf 'fm-upstream-behind-check: could not write %s\n' "$DRIFT_CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$DRIFT_REGISTER_BIN" "$DRIFT_CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    drift_arm_rollback
    printf 'fm-upstream-behind-check: could not register %s\n' "$DRIFT_CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  printf 'armed: state/%s.check.sh\n' "$DRIFT_CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$DRIFT_CHECK_SHIM" "$DRIFT_CHECK_TRUST" "$DRIFT_RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$DRIFT_CHECK_ID"
  return 0
}

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

case "${1:-}" in
  check|arm|disarm)
    [ $# -eq 1 ] || { usage >&2; exit 1; }
    # Sourced only on these paths, so a plain refresh - the one the bearings
    # digest depends on - keeps loading exactly what it loaded before.
    # shellcheck source=bin/fm-pr-lib.sh
    . "$SCRIPT_DIR/fm-pr-lib.sh"
    # shellcheck source=bin/fm-line-cap-lib.sh
    . "$SCRIPT_DIR/fm-line-cap-lib.sh"
    case "$1" in
      check) action_check ;;
      arm) action_arm ;;
      disarm) action_disarm ;;
    esac
    exit $?
    ;;
esac

force=0
if [ "${1:-}" = "--force" ]; then
  force=1
  shift
fi
[ $# -eq 0 ] || { usage >&2; exit 1; }

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

PUBLISH_CHECKED_AT=""

publish() {  # <status> [key=value...] - one line per field, newline-joined.
  local status=$1 block stamp
  shift
  stamp=${PUBLISH_CHECKED_AT:-$(now)}
  block="status=$status"
  for kv in "$@"; do block="$block
$kv"; done
  block="$block
checked_at=$stamp"
  printf '%s\n' "$block" | write_atomic "$REPORT_FILE" || true
  printf '%s\n' "$block"
}

PRIOR_STATUS=$(report_field status)
PRIOR_BEHIND=$(report_field behind)
PRIOR_AHEAD=$(report_field ahead)
PRIOR_NEWEST=$(report_field newest_upstream_date)
PRIOR_CHECKED=$(report_field checked_at)
PRIOR_STALE_BEHIND=$(report_field stale_behind)
PRIOR_STALE_AHEAD=$(report_field stale_ahead)
PRIOR_STALE_NEWEST=$(report_field stale_newest_upstream_date)
PRIOR_STALE_CHECKED=$(report_field stale_checked_at)

degrade() {  # <reason> - publish an unknown that carries any last-known-good forward.
  local fields
  fields=("reason=$1")
  local s_behind=$PRIOR_STALE_BEHIND s_ahead=$PRIOR_STALE_AHEAD
  local s_newest=$PRIOR_STALE_NEWEST s_checked=$PRIOR_STALE_CHECKED
  if [ "$PRIOR_STATUS" = ok ]; then
    s_behind=$PRIOR_BEHIND
    s_ahead=$PRIOR_AHEAD
    s_newest=$PRIOR_NEWEST
    s_checked=$PRIOR_CHECKED
  fi
  [ -z "$s_behind" ] || fields+=("stale_behind=$s_behind")
  [ -z "$s_ahead" ] || fields+=("stale_ahead=$s_ahead")
  [ -z "$s_newest" ] || fields+=("stale_newest_upstream_date=$s_newest")
  if [ -n "$s_checked" ]; then
    fields+=("stale_checked_at=$s_checked")
    case "$s_checked" in
      *[!0-9]*) ;;
      *)
        if [ "$(( $(now) - s_checked ))" -lt "$interval" ]; then
          PUBLISH_CHECKED_AT=$s_checked
        fi
        ;;
    esac
  fi
  publish unknown "${fields[@]}"
}

if [ "${FM_UPSTREAM_NO_PROBE:-0}" = 1 ]; then
  degrade timeout-budget
  exit 0
fi

if ! git -C "$FM_ROOT" remote get-url upstream >/dev/null 2>&1; then
  degrade no-upstream-remote
  exit 0
fi

default=$(default_branch "$FM_ROOT") || {
  degrade no-default-branch
  exit 0
}

timeout="${FM_UPSTREAM_CHECK_TIMEOUT:-20}"
case "$timeout" in ''|*[!0-9]*|0) timeout=20 ;; esac

if ! fm_run_timed "$timeout" git -C "$FM_ROOT" fetch --quiet --no-tags upstream "$default" >/dev/null 2>&1; then
  # A fetch failure is ambiguous: the remote may be unreachable, or reachable
  # but simply missing this branch (the default branch is resolved from
  # *origin*'s HEAD, which need not match upstream's). One bounded ls-remote
  # settles it - exit status 2 means the remote answered and has no such ref,
  # anything else leaves the remote itself in doubt - so the offline worst case
  # stays at two bounds, not three.
  fm_run_timed "$timeout" git -C "$FM_ROOT" ls-remote --quiet --exit-code upstream "refs/heads/$default" >/dev/null 2>&1
  case $? in
    2) degrade no-default-branch ;;
    *) degrade unreachable ;;
  esac
  exit 0
fi

if ! git -C "$FM_ROOT" show-ref --verify --quiet "refs/remotes/upstream/$default" \
  || ! git -C "$FM_ROOT" show-ref --verify --quiet "refs/heads/$default"; then
  degrade no-default-branch
  exit 0
fi

counts=$(git -C "$FM_ROOT" rev-list --left-right --count \
  "refs/remotes/upstream/$default...refs/heads/$default" 2>/dev/null) || counts=
if [ -z "$counts" ]; then
  degrade unreachable
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
      .agents/skills/*/*)
        area_agents_skills=$((area_agents_skills + 1))
        skill_name=${changed_file#.agents/skills/}
        skill_name=${skill_name%%/*}
        case " $skills_list " in
          *" $skill_name "*) : ;;
          *) skills_list="$skills_list $skill_name" ;;
        esac
        ;;
      .agents/skills/*) area_agents_skills=$((area_agents_skills + 1)) ;;
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
