#!/usr/bin/env bash
# Exact browser ownership cleanup through the public teardown executable.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-teardown-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-lib.sh"
fm_git_identity fmtest fmtest@example.invalid
case_dir=$(make_case browser-ownership)
write_meta "$case_dir" no-mistakes ship
land_shippable_commit "$case_dir"
# All processes start outside task cwd, bypassing existing cwd-based reaping.
fm_test_browser_start "$case_dir/state/task-x1" sleep 300
owned=$FM_TEST_BROWSER_PID
# Force the Linux case to prove marker discovery without a recorded PID.
if [ -r "/proc/$owned/environ" ]; then
  rm "$case_dir/state/task-x1.browsers"
fi
fm_test_browser_start "$case_dir/state/task-other" sleep 300
other=$FM_TEST_BROWSER_PID
sleep 300 &
unmarked=$!
FM_TEST_BROWSER_PIDS+=("$unmarked")
# A stale record must not attribute this unrelated live PID to the task.
printf '%s\t%s\n' "$unmarked" 'Mon Jan  1 00:00:00 1900' >>"$case_dir/state/task-x1.browsers"
# Teardown must conclude an active pipeline before stopping its browsers.
head=$(git -C "$case_dir/wt" rev-parse HEAD)
mv "$case_dir/fakebin/no-mistakes" "$case_dir/fakebin/nm-delegate"
cat >"$case_dir/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-} \${2:-}" = 'axi abort' ]; then
  if kill -0 "$owned" 2>/dev/null; then
    printf 'browser-live-at-abort\n' >"$case_dir/abort-order"
  fi
fi
exec "$case_dir/fakebin/nm-delegate" "\$@"
SH
chmod +x "$case_dir/fakebin/no-mistakes"
rc=0
FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
FM_FAKE_NM_ABORT_LOG="$case_dir/abort-log" \
run_teardown "$case_dir" >"$case_dir/out" 2>"$case_dir/err" || rc=$?
expect_code 0 "$rc" 'browser teardown succeeds'
kill -0 "$owned" 2>/dev/null && fail 'owned browser survived'
kill -0 "$other" 2>/dev/null || fail 'other task browser was killed'
kill -0 "$unmarked" 2>/dev/null || fail 'unmarked process with stale registry was killed'
assert_grep 'browser-live-at-abort' "$case_dir/abort-order" 'pipeline abort precedes browser cleanup'
assert_grep 'reaping task browsers' "$case_dir/err" 'browser cleanup reported'
assert_absent "$case_dir/state/task-x1.browsers" 'own registry retired'
pass 'teardown kills only owned browser processes outside task cwd'

# Portable PID/start registry works even without the Linux marker discovery.
case_dir=$(make_case browser-registry)
write_meta "$case_dir" no-mistakes ship
land_shippable_commit "$case_dir"
sleep 300 &
registered=$!
FM_TEST_BROWSER_PIDS+=("$registered")
stamp=$(TZ=UTC LC_ALL=C ps -p "$registered" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
printf '%s\t%s\n' "$registered" "$stamp" >"$case_dir/state/task-x1.browsers"
run_teardown "$case_dir" >"$case_dir/out" 2>"$case_dir/err" || fail 'registry teardown failed'
kill -0 "$registered" 2>/dev/null && fail 'registered browser survived'
pass 'portable registry cleanup verifies PID and start time'

# A browser that remains alive after TERM/KILL retries must stop teardown
# before its worktree and records are discarded, leaving the retry identity.
case_dir=$(make_case browser-reap-refusal)
write_meta "$case_dir" no-mistakes ship
land_shippable_commit "$case_dir"
fm_test_browser_start "$case_dir/state/task-x1" sleep 300
survivor=$FM_TEST_BROWSER_PID
fm_test_browser_start "$case_dir/state/task-other" sleep 300
other=$FM_TEST_BROWSER_PID
cat >"$case_dir/hold-owned-browser.sh" <<SH
kill() {
  for arg in "\$@"; do
    [ "\$arg" != "$survivor" ] || return 0
  done
  builtin kill "\$@"
}
SH
chmod +x "$case_dir/hold-owned-browser.sh"
meta_before=$(git -C "$case_dir/wt" status --porcelain)
rc=0
BASH_ENV="$case_dir/hold-owned-browser.sh" run_teardown "$case_dir" \
  >"$case_dir/out" 2>"$case_dir/err" || rc=$?
[ "$rc" -ne 0 ] || fail 'surviving owned browser did not refuse teardown'
assert_grep 'did not converge; preserving task records for retry' "$case_dir/err" 'browser refusal is reported'
assert_present "$case_dir/state/task-x1.meta" 'browser refusal removed task metadata'
assert_present "$case_dir/state/task-x1.browsers" 'browser refusal removed retry identity'
assert_present "$case_dir/wt/.git" 'browser refusal removed task worktree'
kill -0 "$survivor" 2>/dev/null || fail 'test survivor was unexpectedly killed'
kill -0 "$other" 2>/dev/null || fail 'browser refusal killed another task browser'
[ "$(git -C "$case_dir/wt" status --porcelain)" = "$meta_before" ] \
  || fail 'browser refusal changed the task worktree'
fm_test_browser_stop "$survivor"
fm_test_browser_stop "$other"
pass 'browser reap refusal preserves task and retry records'
