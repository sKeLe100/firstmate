#!/usr/bin/env bash
# Evidence driver: what the captain's wake channel receives for a quiet PC02
# lane, before/after the staleness-cadence change (real wedge_timer_check).
set -u
ROOT=/home/sean_/.no-mistakes/worktrees/4936102b4bcf/01M1F1830V4CQRKJ69YD6MABR1
TMP=$(mktemp -d); HOME_DIR="$TMP/home"; mkdir -p "$HOME_DIR"/{state,data,config,projects}
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_OPENCODE_LOG="$TMP/opencode.log" FM_WATCH_UNIT_TEST=1
. "$ROOT/bin/fm-watch.sh"
WAKES="$TMP/wakes.log"; : > "$WAKES"
fm_wake_append() { printf '  -> captain wake [%s]: %s\n' "$2" "$3" >> "$WAKES"; }
wake() { :; }; triage_log() { :; }; crew_worktree_written_since() { return 1; }
meta() { printf 'window=firstmate:fm-%s\nharness=%s\nkind=ship\nmodel=%s\n' "$1" "$2" "$3" > "$STATE/$1.meta"; }
show() { if [ -s "$WAKES" ]; then cat "$WAKES"; else echo "  -> (no wake: lane left alone)"; fi; : > "$WAKES"; }

meta pc02-worker opencode pc02-llamaswap/qwen3.6-35b-a3b-dispatch
meta cloud-worker claude claude-sonnet-5

echo "1) cloud lane, quiet 300s (unchanged 240s threshold):"
echo "$(( $(date +%s) - 300 ))" > "$STATE/.stale-since-a"
wedge_timer_check winA "$STATE/.stale-since-a" test "$STATE/.wedge-escalations-a" cloud-worker; show

echo "2) PC02 lane, quiet 300s (documented-normal 4-min local-model turn):"
echo "$(( $(date +%s) - 300 ))" > "$STATE/.stale-since-b"
wedge_timer_check winB "$STATE/.stale-since-b" test "$STATE/.wedge-escalations-b" pc02-worker; show

echo "3) PC02 lane, quiet 700s but its opencode session logged a step 60s ago:"
echo "$(( $(date +%s) - 700 ))" > "$STATE/.stale-since-c"
printf 'ses_live\n' > "$STATE/pc02-worker.opencode-session"
printf 'timestamp=%s level=INFO run=d message=loop session.id=ses_live step=7\n' \
  "$(date -u -d '-60 seconds' +%Y-%m-%dT%H:%M:%S.000Z)" >> "$FM_OPENCODE_LOG"
wedge_timer_check winC "$STATE/.stale-since-c" test "$STATE/.wedge-escalations-c" pc02-worker; show
echo "  quiet-spell timer restarted to $(( $(date +%s) - $(cat "$STATE/.stale-since-c") ))s ago"

echo "4) PC02 lane, quiet 700s and no fresh step (genuinely wedged):"
echo "$(( $(date +%s) - 700 ))" > "$STATE/.stale-since-d"
: > "$FM_OPENCODE_LOG"
printf 'timestamp=%s level=INFO run=d message=loop session.id=ses_live step=7\n' \
  "$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%S.000Z)" >> "$FM_OPENCODE_LOG"
wedge_timer_check winD "$STATE/.stale-since-d" test "$STATE/.wedge-escalations-d" pc02-worker; show
rm -rf "$TMP"
