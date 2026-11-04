#!/usr/bin/env bash
# Portable behavior tests for bin/fm-pc02-hygiene.sh: the read-only PC02
# storage/memory/stray-test report firstmate's heartbeat host check calls.
# A fake ssh runs the shared probe locally against controlled files, so the
# report shape, pressure naming and read-only guarantee are proven without
# contacting PC02.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pc02-hygiene.sh"
TMP_ROOT=$(fm_test_tmproot fm-pc02-hygiene)
mkdir -p "$TMP_ROOT/empty-state" "$TMP_ROOT/pc02-tmp" "$TMP_ROOT/home"
export FM_PC02_OFFLOAD_TMP_ROOT="$TMP_ROOT/pc02-tmp"
export FM_PC02_OFFLOAD_MEMINFO="$TMP_ROOT/meminfo"
export FM_PC02_OFFLOAD_HOST=pc02
printf 'MemTotal:       32000000 kB\nMemTotal-extra: 0 kB\nMemAvailable:   24000000 kB\n' > "$TMP_ROOT/meminfo"
# A fixed disk-free reading keeps the report's numeric fields independent of
# the runner's own filesystem; the probe uses df from PATH.
mkdir -p "$TMP_ROOT/df-bin"
cat > "$TMP_ROOT/df-bin/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture 100000000 80000000 20000000 80%% /fixture\n'
SH
chmod +x "$TMP_ROOT/df-bin/df"
export PATH="$TMP_ROOT/df-bin:$PATH"

fakebin=$(fm_fakebin "$TMP_ROOT/fake")
export FM_HYGIENE_FAKE_HOME="$TMP_ROOT/home"
cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift
case "$*" in
  *fm-pc02-hygiene-probe*) HOME="$FM_HYGIENE_FAKE_HOME" bash -c "$*"; exit $? ;;
esac
echo "unexpected fake ssh command" >&2
exit 255
SH
chmod +x "$fakebin/ssh"
export PATH="$fakebin:$PATH"

test_report_is_data_only_and_ok_when_within_bounds() {
  local out status
  out=$(FM_PC02_OFFLOAD_MEM_MIN_FREE_MB=1024 \
    FM_PC02_OFFLOAD_TMP_MIN_FREE_MB=1024 \
    FM_PC02_OFFLOAD_DISK_MIN_FREE_MB=1024 \
    FM_PC02_HYGIENE_IDLE_AGE_SECS=999999999 \
    FM_PC02_HYGIENE_STALE_ROOTS_MAX=0 \
    FM_PC02_HYGIENE_OLD_PROCS_MAX=0 "$SCRIPT" 2>&1)
  status=$?
  expect_code 0 "$status" "a within-bounds PC02 must report ok: $out"
  assert_contains "$out" "mem_available_mib=23437" "MemAvailable was not converted to MiB: $out"
  assert_contains "$out" "tmp_free_mib=" "the report omitted /tmp free space: $out"
  assert_contains "$out" "disk_free_mib=19531" "the report omitted disk free space: $out"
  assert_contains "$out" "stale_test_roots=0" "a clean host reported stale roots: $out"
  assert_contains "$out" "old_test_procs=0" "a clean host reported old test processes: $out"
  assert_contains "$out" "pressure=-" "a clean host reported a pressure field: $out"
  assert_contains "$out" "status=ok" "a clean host did not report ok: $out"
  pass "the hygiene report prints memory, /tmp, disk, stale roots and old processes as data"
}

test_report_names_each_crossed_bound_and_never_deletes() {
  local out status root
  root="$FM_PC02_OFFLOAD_TMP_ROOT/fm-test-run.stale"
  mkdir -p "$root/read-only"
  printf 'x\n' > "$root/read-only/file"
  chmod 500 "$root/read-only"
  touch -d '3 hours ago' "$root"
  bash -c 'exec -a fm-test-run-old sleep 30' &
  local proc=$!
  out=$(FM_PC02_OFFLOAD_MEM_MIN_FREE_MB=999999999 \
    FM_PC02_OFFLOAD_TMP_MIN_FREE_MB=999999999 \
    FM_PC02_OFFLOAD_DISK_MIN_FREE_MB=999999999 \
    FM_PC02_HYGIENE_STALE_AGE_SECS=3600 \
    FM_PC02_HYGIENE_IDLE_AGE_SECS=0 \
    FM_PC02_HYGIENE_STALE_ROOTS_MAX=0 \
    FM_PC02_HYGIENE_OLD_PROCS_MAX=0 "$SCRIPT" 2>&1)
  status=$?
  kill "$proc" 2>/dev/null || true
  wait "$proc" 2>/dev/null || true
  expect_code 1 "$status" "a bound-crossing report must exit 1: $out"
  assert_contains "$out" "stale_test_roots=1" "the stale test root was not counted: $out"
  assert_contains "$out" "status=pressure" "the report did not name pressure: $out"
  assert_contains "$out" "pressure=" "the report omitted its pressure field: $out"
  case "$out" in
    *mem_available*) : ;;
    *) fail "the pressure list omitted MemAvailable: $out" ;;
  esac
  case "$out" in
    *tmp_free*) : ;;
    *) fail "the pressure list omitted /tmp free: $out" ;;
  esac
  case "$out" in
    *disk_free*) : ;;
    *) fail "the pressure list omitted disk free: $out" ;;
  esac
  case "$out" in
    *stale_test_roots*) : ;;
    *) fail "the pressure list omitted stale test roots: $out" ;;
  esac
  case "$out" in
    *old_test_procs*) : ;;
    *) fail "the pressure list omitted old test processes: $out" ;;
  esac
  [ -d "$root" ] || fail "the read-only report deleted a stale root; it must never remove anything"
  pass "the hygiene report names every crossed bound and never deletes or kills"
}

test_unreadable_capacity_is_unknown_not_free() {
  local out status
  out=$(FM_PC02_OFFLOAD_MEMINFO="$TMP_ROOT/no-such-meminfo" "$SCRIPT" 2>&1)
  status=$?
  expect_code 2 "$status" "an unreadable capacity reading must exit 2: $out"
  assert_contains "$out" "unreadable field" "an unreadable capacity reading was not named: $out"
  pass "an unreadable capacity reading is unknown rather than evidence of free space"
}

test_malformed_local_setting_is_refused() {
  local out status
  out=$(FM_PC02_HYGIENE_STALE_AGE_SECS=abc "$SCRIPT" 2>&1)
  status=$?
  expect_code 2 "$status" "a malformed local setting must exit 2: $out"
  assert_contains "$out" "FM_PC02_HYGIENE_STALE_AGE_SECS must be a non-negative integer" \
    "the malformed setting was not named: $out"
  pass "a malformed local setting refuses loudly instead of reporting a wrong bound"
}

test_help_prints_the_read_only_contract() {
  local out status
  out=$("$SCRIPT" --help 2>&1)
  status=$?
  expect_code 0 "$status" "--help must exit 0: $out"
  assert_contains "$out" "read-only" "--help omitted the read-only guarantee: $out"
  assert_contains "$out" "FM_PC02_OFFLOAD_MEM_MIN_FREE_MB" "--help omitted the memory floor: $out"
  assert_contains "$out" "never kills" "--help omitted the no-kill guarantee: $out"
  pass "--help prints the read-only report contract"
}

test_report_is_data_only_and_ok_when_within_bounds
test_report_names_each_crossed_bound_and_never_deletes
test_unreadable_capacity_is_unknown_not_free
test_malformed_local_setting_is_refused
test_help_prints_the_read_only_contract

echo "# all fm-pc02-hygiene tests passed"
