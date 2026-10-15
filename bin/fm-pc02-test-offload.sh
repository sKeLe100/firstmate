#!/usr/bin/env bash
# fm-pc02-test-offload.sh - single owner of routing a heavy fm-test-run.sh
# invocation to PC02 when PC02 is idle from LLM duty AND not the captain's
# personal machine right now, falling back to running it on PC01 whenever
# PC02 is busy, personally in use, unreachable, unready, or the transfer
# fails.
#
# Why: on PC01 the no-mistakes test step (bin/fm-test-run.sh --changed
# --exclude-family real-herdr-gated) repeatedly hits the 30-minute test-agent
# deadline under host load. PC02 has stronger hardware and, when its
# llama-swap serving stack is not holding a model for a live task and the
# captain is not using it personally (gaming, etc.), sits idle.
# fm-test-run.sh's --pc02-if-idle flag execs into this script instead of
# running the suite itself (see fm-test-run.sh's header); this script decides
# local vs remote and, for remote, owns the transfer and execution mechanics.
#
# Reused rather than reinvented:
#   - "is PC02 serving an LLM for firstmate" is
#     bin/fm-autonomous-pc02-lane.sh's existing local, bounded scan of
#     state/*.meta for a live pc02-llamaswap/* task - the same occupancy
#     signal bin/fm-spawn.sh's pc02_lane_guard already treats as
#     authoritative.
#   - ssh access ("ssh pc02" lands in PC02's WSL) is the path documented in
#     docs/pc02-outage-runbook.md, which also owns llama-swap's tailnet
#     address (FM_PC02_OFFLOAD_LLAMASWAP_URL's default) used by the
#     llama-swap occupancy check below.
#   - git-dir/git-common-dir resolution is fm-primary-scope-lib.sh's
#     fm_resolve_git_path, needed because this script's own worktree is
#     typically a linked git worktree (bin/fm-spawn.sh's isolated task
#     worktree), whose ".git" is a pointer file rather than the real store.
#
# Personal-use routing (captain-authorized 2026-09-24, "There will need to be
# a check or switch in place for when PC02 is being used for personal use or
# not"), evaluated fresh at every run, each layer logged as one line and any
# hit routing to PC01:
#   1. Manual switch: a flag file in PC02's own home directory
#      (bin/fm-pc02-personal-use.sh owns the PC01-side on/off/status toggle;
#      docs/pc02-outage-runbook.md documents the captain's no-terminal
#      Windows desktop toggle that writes the same file).
#   2. Automatic: PC02's own llama-swap /running endpoint listing any loaded
#      model (any live LLM session, not just one firstmate dispatched; an
#      idle llama-swap with nothing loaded does not count, and one that is
#      not answering at all is serving nothing), Windows-side CPU and
#      GPU utilization (a game or other heavy foreground use shows up here
#      without needing per-process foreground-window detection), each
#      against a configurable busy threshold.
#   3. Default to PC01 whenever PC02 is unreachable or a check's output does
#      not parse cleanly - never treat an unclear read as an idle host.
#
# Every readiness check is local or one bounded ssh call; a stuck or slow
# probe times out and this script falls back to running locally rather than
# hanging waiting on PC02. Once a check has committed to a remote run it
# never also runs the suite again locally (the two would double whatever
# time budget the caller enforces, such as no-mistakes' 30-minute test-agent
# deadline); the remote execution itself is still bounded
# (FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS, enforced by `timeout` on PC02 itself so
# the remote suite's session is killed there rather than orphaned
# behind a dropped ssh client), and a run that hits this bound is reported
# as a failure rather than silently doubling the budget with a second local
# run. An orphaned background process a test leaves running can otherwise
# hold the ssh channel open long after fm-test-run.sh itself has finished on
# PC02 - observed empirically running this repo's own full --changed suite
# through this script, not a hypothetical - so as soon as fm-test-run.sh
# exits there, the rest of its session is killed and its own exit code
# is returned. The per-run PC02 mirror, and any of its processes still
# running, are removed on every exit path, including an interrupt.
#
# Remote run conditions (always applied to an offloaded run):
#   - Serial, per-script bounded: the remote fm-test-run.sh is invoked with
#     --jobs 1 and --per-script-timeout-secs 1500 appended, overriding any
#     --jobs or --per-script-timeout-secs the caller passed, including larger
#     values. The whole run stays capped by FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS
#     (3600s); because the run is serialized, a large --all or --family run
#     or --changed selection may exceed that cap and exit 124.
#   - Host slot: one nonblocking flock on PC02's ~/.fm-pc02-test-slot.lock
#     covers transfer and execution. Contention or an unclear claim routes
#     local. The file is never unlinked: a dead owner's kernel lock is
#     released automatically, so a leftover file or process name is harmless.
#   - Supervising-home selection and per-machine configuration are owned by
#     docs/configuration.md's "PC02 test offload" section.
#
# Usage:
#   fm-pc02-test-offload.sh <fm-test-run.sh args...>
#
# Env overrides:
#   FM_PC02_OFFLOAD_DISABLE=1          always run locally, skipping every
#                                      PC02 check
#   FM_PC02_OFFLOAD_HOST                ssh target (default: pc02)
#   FM_PC02_OFFLOAD_PROBE_TIMEOUT_SECS  bound for the reachability/personal-use/
#                                      resource/tool probe and the post-sync
#                                      HEAD check (default: 15; the resource
#                                      probe's CPU sample alone takes ~1s)
#   FM_PC02_OFFLOAD_SYNC_TIMEOUT_SECS   bound for each rsync transfer
#                                      (default: 180)
#   FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS    bound for the actual remote test run
#                                      (default: 3600); exceeding it fails
#                                      the run (exit 124) rather than falling
#                                      back, since the remote work already
#                                      spent is not worth discarding blind
#   FM_PC02_OFFLOAD_REMOTE_BASE         remote base directory, relative to
#                                      the ssh target's home, holding one
#                                      private mirror (worktree + git store)
#                                      per offload run, removed when the run
#                                      ends so concurrent runs never share one
#                                      (default: .fm-pc02-test-offload)
#   FM_PC02_OFFLOAD_LLAMASWAP_URL       llama-swap base URL as PC02 reaches it
#                                      (default: http://100.67.55.77:8080)
#   FM_PC02_OFFLOAD_REQUIRED_TOOLS      space-separated tool list PC02 must
#                                      have (default: see REQUIRED_TOOLS
#                                      below); override only to reflect a
#                                      real, verified change in what the
#                                      selected suite needs, never to make a
#                                      tool-short PC02 pass anyway.
#   FM_PC02_OFFLOAD_PERSONAL_USE_FLAG   the manual switch's flag file path on
#                                      PC02, relative to its $HOME (default:
#                                      .fm-pc02-personal-use); present = on
#   FM_PC02_OFFLOAD_RESOURCE_CHECK_PS1  the Windows-side resource-check
#                                      script's path as WSL sees it (default:
#                                      /mnt/c/pc02-llm-server/bin/fm-pc02-resource-check.ps1)
#   FM_PC02_OFFLOAD_CPU_BUSY_PCT        Windows-wide CPU%% at/above which PC02
#                                      reads busy (default: 50)
#   FM_PC02_OFFLOAD_GPU_BUSY_PCT        summed Windows GPU-engine utilization%%
#                                      at/above which PC02 reads busy
#                                      (default: 5; idle measures 0)
#
# Exit status: the exact exit code fm-test-run.sh produced, wherever it ran,
# or 124 if the remote run itself exceeded FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS.
# A readiness check that fails (PC02 personally in use, occupied, unreachable,
# missing a required tool, or a sync/verification failure) falls back to a
# local run and never changes the result fm-test-run.sh itself reports.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SELF_DIR/fm-primary-scope-lib.sh"

ARGS=("$@")

HOST="${FM_PC02_OFFLOAD_HOST:-pc02}"
PROBE_TIMEOUT="${FM_PC02_OFFLOAD_PROBE_TIMEOUT_SECS:-15}"
SYNC_TIMEOUT="${FM_PC02_OFFLOAD_SYNC_TIMEOUT_SECS:-180}"
RUN_TIMEOUT="${FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS:-3600}"
SCRIPT_TIMEOUT=1500
REMOTE_BASE="${FM_PC02_OFFLOAD_REMOTE_BASE:-.fm-pc02-test-offload}"
REMOTE_RUN="$REMOTE_BASE/run-$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1)-$$"
REMOTE_WORKTREE="$REMOTE_RUN/worktree"
REMOTE_COMMON="$REMOTE_RUN/common.git"
REMOTE_RUN_CREATED=0
claim_pid=
claim_open=0
claim_tmp=
LLAMASWAP_URL="${FM_PC02_OFFLOAD_LLAMASWAP_URL:-http://100.67.55.77:8080}"
PERSONAL_USE_FLAG="${FM_PC02_OFFLOAD_PERSONAL_USE_FLAG:-.fm-pc02-personal-use}"
RESOURCE_CHECK_PS1="${FM_PC02_OFFLOAD_RESOURCE_CHECK_PS1:-/mnt/c/pc02-llm-server/bin/fm-pc02-resource-check.ps1}"
CPU_BUSY_PCT="${FM_PC02_OFFLOAD_CPU_BUSY_PCT:-50}"
GPU_BUSY_PCT="${FM_PC02_OFFLOAD_GPU_BUSY_PCT:-5}"

# Tools whose absence hard-fails a real test rather than gracefully
# gate-skipping it - actionlint and shellcheck are pinned versions
# bin/fm-lint.sh refuses to run without, ruby is required outright by
# tests/fm-ci-workflow.test.sh (`command -v ruby || fail ...`), and chromium
# is required outright by tests/fm-calm-pi-extension.test.sh's rendered-export
# guard, none of them optional capabilities. A host missing any of these
# would fail differently than PC01, not just thinner, so no-mistakes would
# judge a different outcome. Require them on PC02 too rather than risk that.
REQUIRED_TOOLS="${FM_PC02_OFFLOAD_REQUIRED_TOOLS:-git bash python3 jq node shellcheck actionlint ruby chromium}"

release_claim() {
  if [ "$claim_open" -eq 1 ]; then
    exec 6>&- 7<&-
    claim_open=0
  fi
  if [ -n "$claim_pid" ]; then
    kill "$claim_pid" 2>/dev/null || true
    for _ in $(seq 1 100); do
      kill -0 "$claim_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$claim_pid" 2>/dev/null || true
    wait "$claim_pid" 2>/dev/null || true
    claim_pid=
  fi
  if [ -n "$claim_tmp" ]; then rm -rf "$claim_tmp"; claim_tmp=; fi
}

remove_remote_run() {
  [ "$REMOTE_RUN_CREATED" -eq 1 ] || return 0
  REMOTE_RUN_CREATED=0
  local run_q cleanup_cmd
  run_q=$(printf '%q' "$REMOTE_RUN")
  cleanup_cmd="[ -f $run_q/pgid ] && pkill -KILL -s \"\$(cat $run_q/pgid)\" 2>/dev/null; rm -rf $run_q"
  timeout "$PROBE_TIMEOUT" ssh "$HOST" "bash -lc $(printf '%q' "$cleanup_cmd")" >/dev/null 2>&1 \
    || echo "fm-pc02-test-offload: could not remove PC02 mirror $REMOTE_RUN" >&2
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
on_signal() {  # <exit code>
  exit "$1"
}
trap 'remove_remote_run; release_claim' EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

run_local() {  # <reason>
  echo "fm-pc02-test-offload: $1; running on PC01" >&2
  remove_remote_run
  release_claim
  exec "$SELF_DIR/fm-test-run.sh" "${ARGS[@]}"
}

[ "${FM_PC02_OFFLOAD_DISABLE:-}" != "1" ] || run_local "offload disabled (FM_PC02_OFFLOAD_DISABLE=1)"
command -v ssh >/dev/null 2>&1 || run_local "ssh not available on PC01"
command -v rsync >/dev/null 2>&1 || run_local "rsync not available on PC01"

# 1. Is PC02 serving as an LLM right now? Reuse the fleet's existing
# occupancy scan (local, bounded, no network) rather than a second detector.
# Pass the operational home explicitly: the test runner may execute from a
# validation checkout that has code but no private state directory.
lane_home=${FM_HOME:-}
home_file="${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/test-offload-home"
home_hint="put one absolute operational-home path followed by a newline in $home_file"
if [ -z "$lane_home" ] && { [ -e "$home_file" ] || [ -L "$home_file" ]; }; then
  if ! IFS= read -r lane_home < "$home_file" || [[ "$lane_home" != /* ]]; then
    run_local "supervising home configuration unavailable or invalid ($home_file); $home_hint"
  fi
fi
if [ -z "$lane_home" ] && [ -z "${FM_STATE_OVERRIDE:-}" ]; then
  common=$(fm_resolve_git_path "$ROOT" --git-common-dir) || run_local "cannot resolve supervising primary clone; $home_hint"
  [ "$(basename "$common")" = .git ] || run_local "common git store does not identify a primary clone; $home_hint"
  lane_home=$(dirname "$common")
fi
if [ -z "$lane_home" ]; then
  lane_out=$("$SELF_DIR/fm-autonomous-pc02-lane.sh" 2>&1)
else
  lane_out=$("$SELF_DIR/fm-autonomous-pc02-lane.sh" --home "$lane_home" 2>&1)
fi
lane_rc=$?
if [ "$lane_rc" -ne 0 ] || [ "$lane_out" != "free" ]; then
  run_local "PC02 lane check reported '$lane_out' (rc=$lane_rc)"
fi

# 2. Is PC02 reachable, personally in use, resource-busy, and tool-ready?
# One bounded ssh call answers all four so a stuck or slow probe cannot hang
# this script past PROBE_TIMEOUT seconds. $HOME, $t, and $rc_out below are
# escaped so they expand on PC02 inside the remote shell, never on PC01.
probe_cmd=$(cat <<PROBE
[ -f "\$HOME/$PERSONAL_USE_FLAG" ] && echo "personal-use:on"
for t in $REQUIRED_TOOLS; do command -v "\$t" >/dev/null 2>&1 || echo "missing:\$t"; done
if ls_running=\$(curl -sf --connect-timeout 3 --max-time 5 $(printf '%q' "$LLAMASWAP_URL/running") 2>/dev/null); then
  echo "llama-swap-running:\$(printf '%s' "\$ls_running" | jq -r '.running | length' 2>/dev/null)"
fi
if [ -f "$RESOURCE_CHECK_PS1" ]; then
  rc_win_path=\$(wslpath -w "$RESOURCE_CHECK_PS1" 2>/dev/null)
  rc_out=\$(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -File "\$rc_win_path" 2>/dev/null)
  echo "resource:\$rc_out"
else
  echo "resource:script-missing"
fi
PROBE
)
probe_out=$(timeout "$PROBE_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout="$PROBE_TIMEOUT" \
  -o ConnectionAttempts=1 "$HOST" "bash -lc $(printf '%q' "$probe_cmd")" 2>&1)
probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
  echo "$probe_out" >&2
  run_local "PC02 unreachable (ssh probe exit $probe_rc)"
fi

personal_use=0
missing_tools=
llama_swap_running=0
resource_line=
while IFS= read -r probe_line; do
  case "$probe_line" in
    personal-use:on) personal_use=1 ;;
    missing:*) missing_tools="$missing_tools ${probe_line#missing:}" ;;
    llama-swap-running:*) llama_swap_running="${probe_line#llama-swap-running:}" ;;
    resource:*) resource_line="${probe_line#resource:}" ;;
  esac
done <<PROBE_OUT
$probe_out
PROBE_OUT

# Layer 1 (captain's manual switch): flip with bin/fm-pc02-personal-use.sh
# from PC01 or the no-terminal Windows desktop toggle documented in
# docs/pc02-outage-runbook.md.
[ "$personal_use" -ne 1 ] || run_local "PC02 personal-use switch is on"

# Layer 2 (automatic): any live LLM session at all, not just a firstmate one.
# An unparseable /running answer is Layer 3 - "unclear" - and routes local.
case "$llama_swap_running" in
  0) ;;
  '' | *[!0-9]*) run_local "PC02 llama-swap running-model check unclear (got '$llama_swap_running'); treating as busy" ;;
  *) run_local "PC02 llama-swap has $llama_swap_running model(s) loaded for a live session" ;;
esac

# Layer 2 (automatic): Windows-wide CPU/GPU utilization. A missing or
# unparseable resource line is Layer 3 - "unclear" - and also routes local.
case "$resource_line" in
  cpu=*gpu=*)
    cpu_val=${resource_line#cpu=}
    cpu_val=${cpu_val%% *}
    gpu_val=${resource_line#*gpu=}
    gpu_val=${gpu_val%% *}
    cpu_over=$(awk -v v="$cpu_val" -v t="$CPU_BUSY_PCT" 'BEGIN { print (v + 0 >= t + 0) ? 1 : 0 }' 2>/dev/null)
    gpu_over=$(awk -v v="$gpu_val" -v t="$GPU_BUSY_PCT" 'BEGIN { print (v + 0 >= t + 0) ? 1 : 0 }' 2>/dev/null)
    [ "$cpu_over" = 1 ] && run_local "PC02 host CPU busy (${cpu_val}% >= ${CPU_BUSY_PCT}%)"
    [ "$gpu_over" = 1 ] && run_local "PC02 host GPU busy (${gpu_val}% >= ${GPU_BUSY_PCT}%)"
    ;;
  *)
    run_local "PC02 resource check unclear (got '$resource_line'); treating as busy"
    ;;
esac

if [ -n "$missing_tools" ]; then
  run_local "PC02 missing required tool(s):$missing_tools"
fi
# The same SSH shell owns the lock while waiting for transfer, then runs the
# suite under it. EOF before execution releases it; EOF during execution
# cannot release it ahead of the bounded suite. No PID-file reclamation race.
# shellcheck disable=SC2016 # HOME and command expand on PC02.
claim_cmd='exec 8> "$HOME/.fm-pc02-test-slot.lock" || exit 1
flock -n 8 || exit 75
printf "claimed\n"
IFS= read -r -t '"$((SYNC_TIMEOUT * 3 + PROBE_TIMEOUT * 5))"' command || exit 1
eval "$command"'
# FIFOs keep this compatible with stock macOS Bash (which has no coproc).
claim_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-pc02-claim.XXXXXX") || run_local "cannot prepare claim channel"
mkfifo "$claim_tmp/in" "$claim_tmp/out" || run_local "cannot prepare claim pipes"
exec 6<>"$claim_tmp/in"
timeout --kill-after=5 "$((SYNC_TIMEOUT * 3 + PROBE_TIMEOUT * 5 + RUN_TIMEOUT + 30))" \
  ssh -o BatchMode=yes -o ConnectTimeout="$PROBE_TIMEOUT" \
  "$HOST" "bash -lc $(printf '%q' "$claim_cmd")" \
  6>&- <"$claim_tmp/in" >"$claim_tmp/out" &
claim_pid=$!
exec 7<"$claim_tmp/out"
claim_open=1
if ! IFS= read -r -t "$PROBE_TIMEOUT" claim_reply <&7 || [ "$claim_reply" != claimed ]; then
  kill "$claim_pid" 2>/dev/null || true
  run_local "PC02 test slot busy or claim unavailable"
fi

# 3. Mirror the current worktree onto PC02: working-tree files, this
# worktree's own per-worktree git-dir (HEAD, index, refs, logs), and the
# shared object/ref store it points at (fm-primary-scope-lib.sh's
# fm_resolve_git_path handles both a linked task worktree and a plain
# checkout, where git-dir and git-common-dir are the same path). The mirror
# is a real, self-contained repo on PC02, not a copy of the ".git" pointer
# file a linked worktree actually has, so its own commondir is rewritten to
# point at the mirrored common store below.
git_dir=$(fm_resolve_git_path "$ROOT" --git-dir) || run_local "could not resolve this worktree's git-dir"
git_common_dir=$(fm_resolve_git_path "$ROOT" --git-common-dir) || run_local "could not resolve this worktree's git-common-dir"

mkdir_cmd="mkdir -p $(printf '%q' "$REMOTE_WORKTREE") $(printf '%q' "$REMOTE_COMMON")"
REMOTE_RUN_CREATED=1
mkdir_out=$(timeout "$PROBE_TIMEOUT" ssh "$HOST" "bash -lc $(printf '%q' "$mkdir_cmd")" 2>&1)
mkdir_rc=$?
if [ "$mkdir_rc" -ne 0 ]; then
  echo "$mkdir_out" >&2
  run_local "could not create PC02 mirror directories (exit $mkdir_rc)"
fi

sync_log=$(timeout "$SYNC_TIMEOUT" rsync -az --delete -e ssh --exclude='/.git' \
  "$ROOT/" "$HOST:$REMOTE_WORKTREE/" 2>&1)
sync_rc=$?
if [ "$sync_rc" -eq 0 ]; then
  sync_log2=$(timeout "$SYNC_TIMEOUT" rsync -az --delete -e ssh --exclude=commondir --exclude=gitdir \
    "$git_dir/" "$HOST:$REMOTE_WORKTREE/.git/" 2>&1)
  sync_rc=$?
  sync_log="$sync_log
$sync_log2"
fi
if [ "$sync_rc" -eq 0 ]; then
  sync_log3=$(timeout "$SYNC_TIMEOUT" rsync -az --delete -e ssh --exclude=worktrees \
    "$git_common_dir/" "$HOST:$REMOTE_COMMON/" 2>&1)
  sync_rc=$?
  sync_log="$sync_log
$sync_log3"
fi
if [ "$sync_rc" -ne 0 ]; then
  echo "$sync_log" >&2
  run_local "rsync to PC02 failed or timed out (exit $sync_rc)"
fi

# The mirrored per-worktree git-dir still has its original commondir/gitdir
# pointers excluded above (a stale one would point back at a PC01-only
# path); point commondir at the sibling common-store mirror instead.
retarget_cmd="printf '%s' '../../common.git' > $(printf '%q' "$REMOTE_WORKTREE/.git/commondir")"
retarget_out=$(timeout "$PROBE_TIMEOUT" ssh "$HOST" "bash -lc $(printf '%q' "$retarget_cmd")" 2>&1)
retarget_rc=$?
if [ "$retarget_rc" -ne 0 ]; then
  echo "$retarget_out" >&2
  run_local "could not retarget PC02 mirror's git commondir (exit $retarget_rc)"
fi

# 3b. Verify the mirror actually resolves to the same commit before spending
# the real test budget on it; a mismatch means the reconstructed repo is
# broken, not that PC02 has a different (or newer) commit to test.
local_head=$(git -C "$ROOT" rev-parse HEAD 2>&1) || run_local "could not read local HEAD"
head_cmd="cd $(printf '%q' "$REMOTE_WORKTREE") && git rev-parse HEAD"
remote_head=$(timeout "$PROBE_TIMEOUT" ssh "$HOST" "bash -lc $(printf '%q' "$head_cmd")" 2>&1)
head_rc=$?
if [ "$head_rc" -ne 0 ] || [ "$remote_head" != "$local_head" ]; then
  echo "$remote_head" >&2
  run_local "PC02 mirror HEAD verification failed (local=$local_head remote=$remote_head rc=$head_rc)"
fi

# 4. Run the exact same fm-test-run.sh invocation on PC02, streaming its
# output live; its exit code becomes this script's exit code unchanged.
# Bounded by RUN_TIMEOUT on PC02 itself: an orphaned background process a
# test leaves running there can hold the ssh channel open long after
# fm-test-run.sh itself exits (see header), so this is not merely defensive.
# The remote `timeout` bounds the run; the wrapper kills its session when
# fm-test-run.sh returns, including nested per-script timeout groups, so a
# straggler cannot pin the channel;
# the local one is only a backstop for a wedged ssh connection. A run
# that hits this bound fails outright (exit 124) rather than falling back to
# a second local run, which would silently double the caller's time budget.
echo "fm-pc02-test-offload: PC02 idle and ready; running tests remotely on $HOST" >&2
remote_suite_cmd="setsid timeout --kill-after=10 $(printf '%q' "$RUN_TIMEOUT") bin/fm-test-run.sh"
for a in "${ARGS[@]}"; do
  remote_suite_cmd="$remote_suite_cmd $(printf '%q' "$a")"
done
remote_suite_cmd="$remote_suite_cmd --jobs 1"
remote_suite_cmd="$remote_suite_cmd --per-script-timeout-secs $(printf '%q' "$SCRIPT_TIMEOUT")"
# The watcher reads the ssh stdin: if the transport drops, EOF kills the suite
# session. The lock (fd 8) is held by the suite itself, so a surviving old
# suite keeps the slot until it actually terminates.
# Keep job control off: setsid must exec in place so $! is the session ID
# written to pgid and used to clean up the complete suite session.
remote_test_cmd="exec 5<&0
cd $(printf '%q' "$REMOTE_WORKTREE") || exit 1
$remote_suite_cmd &
pgid=\$!
echo \"\$pgid\" > ../pgid
(exec 8>&-; while read -r _; do :; done; pkill -KILL -s \"\$pgid\" 2>/dev/null) <&5 &
watcher=\$!
wait \"\$pgid\"
rc=\$?
kill \"\$watcher\" 2>/dev/null
pkill -KILL -s \"\$pgid\" 2>/dev/null
exit \"\$rc\""
# printf %q keeps the multiline command as one protocol line. Execution is
# inside the lock-owning SSH shell, so its descendants also retain the lock.
printf '%s\n' "$(printf '%q' bash) -c $(printf '%q' "$remote_test_cmd")" >&6 || exit 1
cat <&7 6>&- &
stream_pid=$!
wait "$claim_pid"
rc=$?
claim_pid=
wait "$stream_pid" || true
if [ "$rc" -eq 124 ]; then
  echo "fm-pc02-test-offload: remote run on PC02 exceeded ${RUN_TIMEOUT}s (FM_PC02_OFFLOAD_RUN_TIMEOUT_SECS); failing rather than doubling the budget with a local retry" >&2
fi

# A --json artifact lands on PC02's mirror; pull it back so callers reading
# the local path (no-mistakes evidence, hint-drift checks) still see it.
json_path=
prev=
for a in "${ARGS[@]}"; do
  [ "$prev" != "--json" ] || json_path="$a"
  case "$a" in
    --json=*) json_path="${a#--json=}" ;;
  esac
  prev="$a"
done
if [ -n "$json_path" ]; then
  case "$json_path" in
    /*) remote_json="$json_path"; local_json="$json_path" ;;
    *) remote_json="$REMOTE_WORKTREE/$json_path"; local_json="$ROOT/$json_path" ;;
  esac
  mkdir -p "$(dirname "$local_json")" 2>/dev/null || true
  timeout "$SYNC_TIMEOUT" rsync -az -e ssh "$HOST:$remote_json" "$local_json" >/dev/null 2>&1 \
    || echo "fm-pc02-test-offload: could not retrieve --json artifact from PC02 ($json_path)" >&2
fi

exit "$rc"
