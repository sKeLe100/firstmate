#!/usr/bin/env bash
# tests/fm-test-sandbox-cache-race.test.sh - regression test for the
# fm_test_base_path() sandbox-cache race.
#
# Spawns several concurrent callers that hit a freshly-cleared cache so the
# check-build-mark sequence runs simultaneously.  Before the lock fix the
# .complete marker could be written while most symlinks were still missing;
# the populated() check would then pass on a partially-built cache.  After
# the fix every caller must wait for the lock, see a fully-populated cache,
# and all callers must agree on the same cache path.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NUM_WORKERS=8
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/.fm-test-race.XXXXXX") || fail "cannot create work dir"

# Clear any stale sandbox cache so every worker enters the build path.
rm -rf "${TMPDIR:-/tmp}/.fm-test-sandbox-base-path."*

WORKERS=()
RESULTS_FILE=$(mktemp "$WORK_DIR/results.XXXXXX") || fail "cannot create results file"

for i in $(seq 1 "$NUM_WORKERS"); do
  (
    TMPDIR="$WORK_DIR" BASE_PATH=$(fm_test_base_path)
    # Verify the returned path is a real directory we own.
    [ -d "$BASE_PATH" ] && [ ! -L "$BASE_PATH" ] && [ -O "$BASE_PATH" ] \
      || { echo "FAIL:$i" >> "$RESULTS_FILE"; exit 1; }
    # Reuse fm_test_base_path_populated rather than reimplementing the same
    # enumeration logic, so the test asserts the exact contract being fixed.
    fm_test_base_path_populated "$BASE_PATH" \
      || { echo "SPARSE:$i" >> "$RESULTS_FILE"; exit 1; }
    echo "OK:$i:$BASE_PATH" \
      >> "$RESULTS_FILE"
    echo "$BASE_PATH"
  ) &
  WORKERS+=($!)
done

# Wait for every worker.
FAIL=0
for pid in "${WORKERS[@]}"; do
  wait "$pid" || FAIL=1
done

# Collect unique cache paths from successful workers.
CACHE_PATHS=$(grep '^OK:' "$RESULTS_FILE" 2>/dev/null | cut -d: -f3 | sort -u)
UNIQUE_COUNT=$(printf '%s\n' "$CACHE_PATHS" | grep -c . || true)

# Fail if any worker crashed.
if [ "$FAIL" -ne 0 ]; then
  fail "one or more concurrent workers crashed (see results file: $RESULTS_FILE)"
fi

# All successful workers must agree on the same cache path.
if [ "$UNIQUE_COUNT" -ne 1 ]; then
  fail "workers disagreed on cache path (unique paths: $UNIQUE_COUNT): $CACHE_PATHS"
fi

rm -rf "$WORK_DIR" "$RESULTS_FILE"
pass "concurrent sandbox-build race: $NUM_WORKERS workers agree on one fully-populated cache"
