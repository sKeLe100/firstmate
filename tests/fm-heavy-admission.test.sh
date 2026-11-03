#!/usr/bin/env bash
# Host slot contention, resource floors, bounded wait, and inspection exemptions.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-heavy-admission)
LIB="$ROOT/bin/fm-heavy-admission-lib.sh"
export FM_HEAVY_SLOT="$TMP_ROOT/slot" FM_HEAVY_WAIT_SECS=0
export FM_HEAVY_MAX_LOAD5=8 FM_HEAVY_MIN_MEM_KIB=3145728
admit() { bash -c '. "$1"; fm_heavy_admit fixture' bash "$LIB"; }

admit >"$TMP_ROOT/free" 2>&1 || fail 'free host refused'
assert_grep 'admitted fixture' "$TMP_ROOT/free" 'free slot admission'
pass 'free host admitted and lock released on exit'

# Hold the very same inode from a different admission, with a named owner.
FM_TASK_ID=other-heavy-run bash -c '
  . "$1"
  fm_heavy_admit other-heavy-run || exit $?
  : >"$2"
  sleep 600
' bash "$LIB" "$TMP_ROOT/ready" >"$TMP_ROOT/holder" 2>&1 &
holder=$!
trap 'kill "$holder" "${leaked:-}" "${reused:-}" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fm_test_cleanup' EXIT
for ((i=0;i<100;i++)); do [ ! -f "$TMP_ROOT/ready" ] || break; sleep 0.1; done
[ -f "$TMP_ROOT/ready" ] || fail 'holder not ready'
rc=0; admit >"$TMP_ROOT/busy" 2>&1 || rc=$?
expect_code 75 "$rc" 'busy host refused'
assert_grep 'other-heavy-run' "$TMP_ROOT/busy" 'busy refusal names owner'
assert_no_grep 'reclaimed stale slot' "$TMP_ROOT/busy" 'a live owner is never reclaimed'
pass 'busy host refuses without overlapping holder'

# PC02 offload suites are governed by the offload slot locks, not this host slot.
( FM_PC02_OFFLOAD_REMOTE=1 admit >"$TMP_ROOT/remote-1" 2>&1 ) & remote_1=$!
( FM_PC02_OFFLOAD_REMOTE=1 admit >"$TMP_ROOT/remote-2" 2>&1 ) & remote_2=$!
rc_1=0; wait "$remote_1" || rc_1=$?
rc_2=0; wait "$remote_2" || rc_2=$?
expect_code 0 "$rc_1" 'first PC02 offload admission'
expect_code 0 "$rc_2" 'second PC02 offload admission'
assert_grep 'admitted fixture on PC02 offload' "$TMP_ROOT/remote-1" 'first PC02 offload admitted'
assert_grep 'admitted fixture on PC02 offload' "$TMP_ROOT/remote-2" 'second PC02 offload admitted'
assert_no_grep 'slot-busy' "$TMP_ROOT/remote-1" 'first PC02 offload did not take the host slot'
assert_no_grep 'slot-busy' "$TMP_ROOT/remote-2" 'second PC02 offload did not take the host slot'
pass 'two PC02 offload slots both admit while a local heavy run holds the host slot'

# A minimal executable fixture proves targeted execution rather than running an
# unrelated real suite inside this contract test.
mkdir -p "$TMP_ROOT/repo/bin" "$TMP_ROOT/repo/tests"
cp "$ROOT/bin/fm-test-run.sh" "$LIB" "$TMP_ROOT/repo/bin/"
cp "$ROOT/tests/git-config-helpers.sh" "$TMP_ROOT/repo/tests/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/repo/tests/fm-brief.test.sh"
rc=0
"$TMP_ROOT/repo/bin/fm-test-run.sh" tests/fm-brief.test.sh >"$TMP_ROOT/targeted" 2>&1 || rc=$?
expect_code 0 "$rc" 'targeted test is exempt from the host slot'
assert_no_grep 'other-heavy-run' "$TMP_ROOT/targeted" 'targeted run does not inspect the host slot'
pass 'explicit script paths remain exempt from the host slot'

# Both real heavy entry points refuse BEFORE executing work.
for command in tests lint; do
  rc=0
  if [ "$command" = tests ]; then
    "$TMP_ROOT/repo/bin/fm-test-run.sh" --family pure-contract-unit >"$TMP_ROOT/$command" 2>&1 || rc=$?
  else
    "$ROOT/bin/fm-lint.sh" >"$TMP_ROOT/$command" 2>&1 || rc=$?
  fi
  expect_code 75 "$rc" "$command shares the host slot"
done
pass 'heavy tests and full lint use the same slot'
kill "$holder"; wait "$holder" 2>/dev/null || true

# A killed run can leave a descendant holding fd 9 after the recorded owner is
# gone, so the flock never frees. A reused pid must not pass as the owner: its
# live start identity differs from the record, so the stale record is reclaimed
# instead of blocking this run for its whole bounded wait.
sleep 600 & reused=$!
perl -e 'open(my $f, ">>", $ARGV[0]) or die $!; flock($f,2) or die $!;
  truncate($f, 0) or die $!; seek($f, 0, 0) or die $!;
  print $f "pid=$ARGV[1] start=starttime=0 task=leaked-owner run=tests:changed\n"; $f->flush();
  open(my $ready, ">", $ARGV[2]) or die $!; close $ready; sleep 600' \
  "$FM_HEAVY_SLOT" "$reused" "$TMP_ROOT/leaked-ready" &
leaked=$!
for ((i=0;i<100;i++)); do [ ! -f "$TMP_ROOT/leaked-ready" ] || break; sleep 0.1; done
[ -f "$TMP_ROOT/leaked-ready" ] || fail 'leaked holder not ready'
kill -0 "$reused" 2>/dev/null || fail 'reused pid fixture is not running'
rc=0; FM_HEAVY_WAIT_SECS=10 admit >"$TMP_ROOT/stale" 2>&1 || rc=$?
kill "$leaked" 2>/dev/null || true; wait "$leaked" 2>/dev/null || true
leaked=
expect_code 0 "$rc" 'stale start identity is reclaimed'
assert_grep "reclaimed stale slot holder=pid=$reused" "$TMP_ROOT/stale" 'reclaim names the stale pid'
[ "$(grep -c 'reclaimed stale slot' "$TMP_ROOT/stale" || true)" -eq 1 ] || fail 'stale reclaim logged more than once'
assert_grep 'admitted fixture' "$TMP_ROOT/stale" 'reclaim admits without the bounded wait'
kill "$reused" 2>/dev/null || true; wait "$reused" 2>/dev/null || true
reused=
pass 'a reused pid with a stale start identity is reclaimed'

rc=0; FM_HEAVY_TEST_LOAD5=8 admit >"$TMP_ROOT/load" 2>&1 || rc=$?
expect_code 75 "$rc" 'load threshold is strict'
assert_grep 'load5=8' "$TMP_ROOT/load" 'load refusal explains threshold'
assert_grep 'need <8' "$TMP_ROOT/load" 'load refusal names the floor'
assert_no_grep 'MemAvailable_KiB=' "$TMP_ROOT/load" 'load refusal names only the floor that was hit'
rc=0; FM_HEAVY_TEST_MEM_KIB=3145727 admit >"$TMP_ROOT/memory" 2>&1 || rc=$?
expect_code 75 "$rc" 'low available memory refused'
assert_grep 'MemAvailable_KiB=3145727' "$TMP_ROOT/memory" 'memory refusal names the measured value'
assert_grep 'need >=3145728' "$TMP_ROOT/memory" 'memory refusal names the floor'
assert_no_grep 'load5=' "$TMP_ROOT/memory" 'memory refusal names only the floor that was hit'
FM_HEAVY_TEST_MEM_KIB=3145728 admit >"$TMP_ROOT/boundary" 2>&1 || fail 'memory floor should be inclusive'
pass 'load and available-memory thresholds enforced'

rc=0; FM_HEAVY_WAIT_SECS=1 FM_HEAVY_POLL_SECS=1 FM_HEAVY_TEST_LOAD5=99 admit >"$TMP_ROOT/wait" 2>&1 || rc=$?
expect_code 75 "$rc" 'bounded resource wait fails'
assert_grep 'waiting 1s' "$TMP_ROOT/wait" 'backoff is logged'
assert_grep 'after 1s' "$TMP_ROOT/wait" 'bounded refusal is logged'
admit >/dev/null 2>&1 || fail 'refusal leaked the slot'
pass 'bounded logged backoff releases slot on refusal'

for setting in poll max_load; do
  rc=0
  case "$setting" in
    poll) FM_HEAVY_POLL_SECS=0 admit >"$TMP_ROOT/zero-$setting" 2>&1 || rc=$? ;;
    max_load) FM_HEAVY_MAX_LOAD5=0 admit >"$TMP_ROOT/zero-$setting" 2>&1 || rc=$? ;;
  esac
  expect_code 2 "$rc" "zero $setting limit rejected"
  assert_grep 'must be greater than zero' "$TMP_ROOT/zero-$setting" "zero $setting limit explains refusal"
done
pass 'zero polling and load limits fail with a diagnostic'

rc=0
FM_HEAVY_SLOT="$TMP_ROOT/missing/slot" admit >"$TMP_ROOT/open-failure" 2>&1 || rc=$?
expect_code 2 "$rc" 'missing slot directory refuses admission'
assert_grep 'could not open slot file for locking' "$TMP_ROOT/open-failure" 'slot open failure is diagnosed'
assert_grep "$TMP_ROOT/missing/slot" "$TMP_ROOT/open-failure" 'slot open diagnostic names its path'
pass 'slot open failure refuses with its path'

rc=0
# The child bash must expand $1 after receiving LIB as its positional argument.
# shellcheck disable=SC2016
FM_HEAVY_SLOT="$TMP_ROOT/write-failure-slot" bash -c '
  printf() {
    [ "${1:-}" != "pid=%s start=%s task=%s run=%s\\n" ] || return 1
    builtin printf "$@"
  }
  . "$1"
  fm_heavy_admit fixture
  result=$?
  [ "$result" -eq 2 ] || exit 90
  if ( : >&9 ) 2>/dev/null; then exit 91; fi
' bash "$LIB" >"$TMP_ROOT/write-failure" 2>&1 || rc=$?
expect_code 0 "$rc" 'holder write failure refuses and releases the slot'
assert_grep 'could not record holder in slot file' "$TMP_ROOT/write-failure" 'holder write failure is diagnosed'
assert_grep "$TMP_ROOT/write-failure-slot" "$TMP_ROOT/write-failure" 'holder write diagnostic names its path'
assert_no_grep 'admitted fixture' "$TMP_ROOT/write-failure" 'holder write failure cannot admit'
pass 'holder write failure refuses and releases the slot'

mkdir -p "$TMP_ROOT/production-home"
production_slot="$TMP_ROOT/production-home/.fm-heavy-run-slot.lock"
test_override_slot="$TMP_ROOT/untrusted-override-slot"
rc=0
# The child bash expands $1 after receiving LIB as its positional argument.
# shellcheck disable=SC2016
env -u FM_TEST_SEAM HOME="$TMP_ROOT/production-home" FM_HEAVY_SLOT="$test_override_slot" \
  FM_HEAVY_WAIT_SECS=0 bash -c '. "$1"; fm_heavy_admit production' bash "$LIB" \
  >"$TMP_ROOT/production-slot" 2>&1 || rc=$?
case "$rc" in 0|75) : ;; *) fail "production slot selection failed unexpectedly: $rc" ;; esac
assert_present "$production_slot" 'production ignored slot was not created'
assert_grep 'run=production' "$production_slot" 'production did not record the shared slot holder'
assert_absent "$test_override_slot" 'production accepted the environment slot override'
pass 'production uses the fixed slot path without the test seam'
