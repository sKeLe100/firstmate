#!/usr/bin/env bash
# Evidence wrapper: run the pinned local selection directly on this host (PC01)
# with a clean environment, to measure the PC01-fallback wall clock and prove
# the filtered selection is green without hosted/PC02 offload.
set -u
cd {run-worktree} || exit 1
EV=~/.no-mistakes/evidence/01M6J0JA19GHKKHAMBC3HJ4NMS
start=$(date +%s)
env -u FM_PC02_OFFLOAD_DISABLE -u FM_TEST_COMPUTE_DISABLE \
  bin/fm-test-run.sh --changed --exclude-family real-herdr-gated --exclude-quarantined
rc=$?
end=$(date +%s)
echo "EXIT=$rc WALL_SECS=$((end-start))"
echo "$rc" > "$EV/gate-local.rc"
