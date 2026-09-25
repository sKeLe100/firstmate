#!/usr/bin/env bash
# Coverage for bin/fm-opencode-session-sweep.sh: an orphaned session file (no
# matching .meta) is removed, a session file whose task is still tracked is
# left alone, and --dry-run reports without mutating.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-session-sweep)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

STATE="$TMP_ROOT/home/state"
mkdir -p "$STATE"
export FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$STATE"

SWEEP="$ROOT/bin/fm-opencode-session-sweep.sh"

# orphan1 has no .meta: torn down before the teardown fix existed.
printf 'ses_orphan1\n' > "$STATE/orphan1.opencode-session"
# tracked has a .meta: still a live or held task, untouchable.
printf 'ses_tracked\n' > "$STATE/tracked.opencode-session"
: > "$STATE/tracked.meta"

out=$("$SWEEP" --dry-run)
rc=$?
[ "$rc" = 0 ] || { echo "not ok: --dry-run exited $rc"; exit 1; }
case "$out" in
  *"ORPHAN (dry-run): orphan1"*) ;;
  *) echo "not ok: --dry-run did not report orphan1: $out"; exit 1 ;;
esac
case "$out" in
  *tracked*) echo "not ok: --dry-run reported tracked task: $out"; exit 1 ;;
esac
assert_present "$STATE/orphan1.opencode-session" "dry-run must not remove the orphan"

out=$("$SWEEP")
rc=$?
[ "$rc" = 0 ] || { echo "not ok: sweep exited $rc"; exit 1; }
case "$out" in
  *"REMOVED: orphan1"*) ;;
  *) echo "not ok: sweep did not report removing orphan1: $out"; exit 1 ;;
esac
assert_absent "$STATE/orphan1.opencode-session" "orphaned session file must be removed"
assert_present "$STATE/tracked.opencode-session" "tracked task's session file must survive"

# A repeat run over an already-clean state is silent and still exits 0.
out=$("$SWEEP")
rc=$?
[ "$rc" = 0 ] || { echo "not ok: repeat sweep exited $rc"; exit 1; }
[ -z "$out" ] || { echo "not ok: repeat sweep printed unexpected output: $out"; exit 1; }

echo "ok: fm-opencode-session-sweep.test.sh"
