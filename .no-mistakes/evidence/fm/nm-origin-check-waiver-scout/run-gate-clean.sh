#!/usr/bin/env bash
# Evidence wrapper: run the pinned gate command with hosted routing disabled.
# No FM_PC02_OFFLOAD_DISABLE here, so the product's own PC02/local admission
# decides where the suite runs and child tests inherit a clean environment.
set -u
cd {run-worktree} || exit 1
EV=~/.no-mistakes/evidence/01M6J0JA19GHKKHAMBC3HJ4NMS
start=$(date +%s)
FM_TEST_COMPUTE_DISABLE=1 bin/fm-test-run.sh --changed --exclude-family real-herdr-gated --exclude-quarantined --pc02-if-idle
rc=$?
end=$(date +%s)
echo "EXIT=$rc WALL_SECS=$((end-start))"
echo "$rc" > "$EV/gate-clean.rc"
