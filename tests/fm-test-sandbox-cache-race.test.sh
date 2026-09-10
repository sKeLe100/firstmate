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

# Remove any pre-existing sandbox cache so every worker enters the build path.
SBOX_DIR="${WORK_DIR}/.fm-test-sandbox-base-path"
rm -rf "$SBOX_DIR"

# Also clear the system-wide lock to avoid stale contention from a prior run.
rm -f "${TMPDIR:-/tmp}/.fm-test-sandbox-lock"

WORKERS=()
RESULTS_FILE=$(mktemp "$WORK_DIR/results.XXXXXX") || fail "cannot create results file"

for i in $(seq 1 "$NUM_WORKERS"); do
  (
    # Each worker gets a clean TMPDIR so it computes the same cache key path
    # (same uid, same source dirs) but a distinct scratch area.  However
    # fm_test_base_path uses "${TMPDIR:-/tmp}/.fm-test-sandbox-base-path.$uid.$key"
    # as the cache path - and the key depends only on uid + source dir contents,
    # so every worker lands on the SAME cache directory inside this work tree.
    TMPDIR="$WORK_DIR" BASE_PATH=$(fm_test_base_path)
    # Verify the returned path is a real directory we own.
    [ -d "$BASE_PATH" ] && [ ! -L "$BASE_PATH" ] && [ -O "$BASE_PATH" ] \
      || { echo "FAIL:$i" >> "$RESULTS_FILE"; exit 1; }
    # Verify every expected tool is linked (the populated check is a no-op
    # on cached paths but a useful self-test).
    for dir in $FM_TEST_BASE_PATH_SOURCE_DIRS; do
      [ -d "$dir" ] || continue
      for fpath in "$dir"/*; do
        [ -x "$fpath" ] || continue
        [ -f "$fpath" ] || continue
        fname=${fpath##*/}
        excluded=0
        for excl in $FM_TEST_FAKED_TOOL_NAMES; do
          [ "$fname" = "$excl" ] && { excluded=1; break; }
        done
        [ "$excluded" -eq 1 ] && continue
        [ -e "$BASE_PATH/$fname" ] \
          || { echo "MISSING:$i:$fname" >> "$RESULTS_FILE"; exit 1; }
      done
    done
    echo "OK:$i:$BASE_PATH" \
      >> "$RESULTS_FILE"
    # Echo the cache path for cross-worker comparison.
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

# Verify the shared cache has a substantial number of links (not just a
# handful), proving the populated() check passed for all workers.
CACHED_PATH=$(printf '%s\n' "$CACHE_PATHS" | head -1)
LINK_COUNT=$(find "$CACHED_PATH" -maxdepth 1 -type l 2>/dev/null | wc -l)
if [ "$LINK_COUNT" -lt 100 ]; then
  fail "sandbox cache too sparse: only $LINK_COUNT links in $CACHED_PATH"
fi

rm -rf "$WORK_DIR" "$RESULTS_FILE"
pass "concurrent sandbox-build race: $NUM_WORKERS workers agree on one fully-populated cache"
