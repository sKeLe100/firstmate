#!/usr/bin/env bash
# Behavior tests for bin/fm-host-memory.sh: the floor read from
# config/host-memory-floor, the MemAvailable comparison, and the fail-closed
# direction on an unreadable source or a malformed floor.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-host-memory)
HELPER="$ROOT/bin/fm-host-memory.sh"

mk_home() {  # <name>
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/config"
  printf '%s' "$h"
}

meminfo() {  # <name> <MemAvailable-kB>
  local f="$TMP_ROOT/$1.meminfo"
  {
    printf 'MemTotal:       14680064 kB\n'
    printf 'MemFree:          204800 kB\n'
    printf 'MemAvailable:   %8s kB\n' "$2"
  } > "$f"
  printf '%s' "$f"
}

emit() {  # <home> <meminfo-path>
  FM_HOME="$1" FM_MEMINFO_OVERRIDE="$2" "$HELPER"
}

test_above_floor_reads_free() {
  local home mi out rc
  home=$(mk_home above)
  mi=$(meminfo above 8388608)   # 8192 MiB, default floor 3072
  out=$(emit "$home" "$mi"); rc=$?
  [ "$rc" -eq 0 ] || fail "8192MiB available must exit 0, got $rc: $out"
  [ "$out" = free ] || fail "expected 'free', got: $out"
  pass "fm-host-memory.sh: MemAvailable above the default floor reads free"
}
test_above_floor_reads_free

test_below_floor_reads_low_and_names_both_numbers() {
  local home mi out rc
  home=$(mk_home below)
  mi=$(meminfo below 1048576)   # 1024 MiB, default floor 3072
  out=$(emit "$home" "$mi") && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "1024MiB available must exit 1, got $rc: $out"
  assert_contains "$out" "1024MiB" "the low line must name what is available"
  assert_contains "$out" "3072MiB" "the low line must name the floor it failed"
  pass "fm-host-memory.sh: MemAvailable below the floor reads low and names both numbers"
}
test_below_floor_reads_low_and_names_both_numbers

test_configured_floor_overrides_the_default() {
  local home mi out rc
  home=$(mk_home configured)
  mi=$(meminfo configured 2097152)   # 2048 MiB
  printf '1024\n' > "$home/config/host-memory-floor"
  out=$(emit "$home" "$mi"); rc=$?
  [ "$rc" -eq 0 ] || fail "2048MiB must clear a configured 1024MiB floor: $out"
  printf '4096\n' > "$home/config/host-memory-floor"
  out=$(emit "$home" "$mi") && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "2048MiB must fail a configured 4096MiB floor, got $rc: $out"
  assert_contains "$out" "4096MiB" "the configured floor must be the one reported"
  pass "fm-host-memory.sh: config/host-memory-floor overrides the built-in default in both directions"
}
test_configured_floor_overrides_the_default

test_malformed_floor_is_rejected_not_defaulted() {
  local home mi out rc bad
  home=$(mk_home malformed)
  mi=$(meminfo malformed 8388608)   # would read free under the default floor
  for bad in "not-a-number" "" "0" "-512" "2048 4096"; do
    printf '%s\n' "$bad" > "$home/config/host-memory-floor"
    out=$(emit "$home" "$mi" 2>&1) && rc=0 || rc=$?
    [ "$rc" -eq 2 ] || fail "malformed floor '$bad' must exit 2, not fall back to the default: rc=$rc out=$out"
    assert_not_contains "$out" "free" "a malformed floor must never read free"
  done
  pass "fm-host-memory.sh: a malformed floor is rejected loudly rather than silently defaulted"
}
test_malformed_floor_is_rejected_not_defaulted

test_unreadable_meminfo_is_fail_closed() {
  local home out rc
  home=$(mk_home unreadable)
  out=$(emit "$home" "$TMP_ROOT/no-such-meminfo" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "a missing meminfo source must exit 2, got $rc: $out"
  assert_not_contains "$out" "free" "an unreadable source must never read free"

  printf 'MemTotal: 14680064 kB\nMemFree: 204800 kB\n' > "$TMP_ROOT/no-avail.meminfo"
  out=$(emit "$home" "$TMP_ROOT/no-avail.meminfo" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "meminfo without MemAvailable must exit 2, got $rc: $out"
  assert_not_contains "$out" "free" "a source with no MemAvailable must never read free"
  pass "fm-host-memory.sh: an unreadable or MemAvailable-less source exits 2 and never reads free"
}
test_unreadable_meminfo_is_fail_closed

test_reads_memavailable_not_memfree() {
  local home f out rc
  home=$(mk_home which_field)
  f="$TMP_ROOT/which-field.meminfo"
  # MemFree alone would read low; MemAvailable is what the kernel says a new
  # workload can claim, and is the number this helper must use.
  {
    printf 'MemTotal:       14680064 kB\n'
    printf 'MemFree:          102400 kB\n'
    printf 'MemAvailable:    8388608 kB\n'
  } > "$f"
  out=$(emit "$home" "$f"); rc=$?
  [ "$rc" -eq 0 ] || fail "the helper must read MemAvailable, not MemFree: rc=$rc out=$out"
  [ "$out" = free ] || fail "expected free from MemAvailable, got: $out"
  pass "fm-host-memory.sh: the verdict comes from MemAvailable, not MemFree"
}
test_reads_memavailable_not_memfree

test_host_memory_floor_is_inheritable_config() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  case " $FM_INHERITABLE_CONFIG " in
    *" host-memory-floor "*) ;;
    *) fail "config/host-memory-floor must be in FM_INHERITABLE_CONFIG so secondmate homes inherit the floor" ;;
  esac
  pass "fm-host-memory.sh: config/host-memory-floor is inherited by secondmate homes"
}
test_host_memory_floor_is_inheritable_config
