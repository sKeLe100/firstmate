#!/usr/bin/env bash
# Behavior tests for dispatch-cap and codex-lane-cap inheritance.
#
# A secondmate home must inherit its lane limits from the primary instead of
# launching with no mechanical cap at all (data/codex-secondmate-standup-plan/
# report.md section 4.2(d)). This tests only that both items are declared
# inheritable and that propagate_inheritable_config actually converges and
# mirrors absence for them - not codex_lane_guard's enforcement logic, which
# is separate follow-up work.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-config-inherit-lane-caps)

# A case below makes a fixture directory unreadable; restore it even when an
# intervening `fail` exits, or the EXIT cleanup cannot descend into it.
UNREADABLE_DIR=""
restore_unreadable() {
  [ -n "$UNREADABLE_DIR" ] || return 0
  chmod 755 "$UNREADABLE_DIR" 2>/dev/null || true
  UNREADABLE_DIR=""
}
trap 'restore_unreadable; fm_test_cleanup' EXIT
trap 'restore_unreadable; fm_test_cleanup; exit 130' INT
trap 'restore_unreadable; fm_test_cleanup; exit 143' TERM

new_home_pair() {
  local name=$1 base primary second
  base="$TMP_ROOT/$name"
  primary="$base/primary"
  second="$base/second"
  mkdir -p "$primary/config" "$second/config"
  printf '%s\n' "$primary|$second"
}

test_dispatch_cap_and_codex_lane_cap_are_inheritable_config() {
  case " $FM_INHERITABLE_CONFIG " in
    *" dispatch-cap "*) ;;
    *) fail "config/dispatch-cap must be in FM_INHERITABLE_CONFIG so secondmate homes inherit the cap" ;;
  esac
  case " $FM_INHERITABLE_CONFIG " in
    *" codex-lane-cap "*) ;;
    *) fail "config/codex-lane-cap must be in FM_INHERITABLE_CONFIG so secondmate homes inherit the cap" ;;
  esac
  pass "config/dispatch-cap and config/codex-lane-cap are inherited by secondmate homes"
}
test_dispatch_cap_and_codex_lane_cap_are_inheritable_config

test_propagation_converges_lane_cap_values() {
  local rec primary second report
  rec=$(new_home_pair converge)
  primary=${rec%%|*}
  second=${rec#*|}
  printf '2\n' > "$primary/config/dispatch-cap"
  printf '1\n' > "$primary/config/codex-lane-cap"
  report="$TMP_ROOT/converge.report"

  propagate_inheritable_config "$primary/config" "$second/config" \
    || fail "propagate_inheritable_config failed converging lane caps"

  cmp -s "$primary/config/dispatch-cap" "$second/config/dispatch-cap" \
    || fail "config/dispatch-cap did not converge to the secondmate"
  cmp -s "$primary/config/codex-lane-cap" "$second/config/codex-lane-cap" \
    || fail "config/codex-lane-cap did not converge to the secondmate"

  FM_CONFIG_INHERIT_REPORT="$report" \
    propagate_inheritable_config "$primary/config" "$second/config" \
    || fail "unchanged reconvergence failed"
  grep -q $'^dispatch-cap\tpushed\t' "$report" \
    && fail "unchanged dispatch-cap should not report pushed on reconvergence"
  grep -q $'^dispatch-cap\tunchanged\t' "$report" \
    || fail "unchanged dispatch-cap should report unchanged on reconvergence"
  grep -q $'^codex-lane-cap\tunchanged\t' "$report" \
    || fail "unchanged codex-lane-cap should report unchanged on reconvergence"
  pass "config/dispatch-cap and config/codex-lane-cap converge to a secondmate and stay idempotent"
}
test_propagation_converges_lane_cap_values

test_primary_absence_mirrors_downstream() {
  local rec primary second
  rec=$(new_home_pair absence)
  primary=${rec%%|*}
  second=${rec#*|}
  printf '3\n' > "$second/config/dispatch-cap"
  printf '2\n' > "$second/config/codex-lane-cap"

  propagate_inheritable_config "$primary/config" "$second/config" \
    || fail "propagate_inheritable_config failed mirroring absence"

  [ -e "$second/config/dispatch-cap" ] \
    && fail "primary absence of config/dispatch-cap must clear the secondmate's copy"
  [ -e "$second/config/codex-lane-cap" ] \
    && fail "primary absence of config/codex-lane-cap must clear the secondmate's copy"
  pass "primary absence of dispatch-cap and codex-lane-cap clears the secondmate's copy"
}
test_primary_absence_mirrors_downstream

test_unreadable_primary_source_reports_error_and_fails() {
  local rec primary second report probe rc
  rec=$(new_home_pair unreadable)
  primary=${rec%%|*}
  second=${rec#*|}
  printf '2\n' > "$primary/config/dispatch-cap"
  printf '1\n' > "$primary/config/codex-lane-cap"
  printf '9\n' > "$second/config/dispatch-cap"
  printf '9\n' > "$second/config/codex-lane-cap"
  report="$TMP_ROOT/unreadable.report"

  UNREADABLE_DIR="$primary/config"
  chmod 000 "$primary/config"
  probe=0
  cat "$primary/config/dispatch-cap" >/dev/null 2>&1 || probe=1
  if [ "$probe" = 0 ]; then
    restore_unreadable
    pass "skipped unreadable-primary-source case: this user can traverse a 0000 directory"
    return 0
  fi

  rc=0
  FM_CONFIG_INHERIT_REPORT="$report" \
    propagate_inheritable_config "$primary/config" "$second/config" \
    2>/dev/null || rc=$?
  restore_unreadable

  [ "$rc" = 1 ] || fail "an uninspectable primary source must fail propagation with rc=1 (got $rc)"
  grep -q $'^dispatch-cap\terror\t' "$report" \
    || fail "an uninspectable config/dispatch-cap source must report error"
  grep -q $'^codex-lane-cap\terror\t' "$report" \
    || fail "an uninspectable config/codex-lane-cap source must report error"
  [ "$(cat "$second/config/dispatch-cap")" = 9 ] \
    || fail "an uninspectable primary source must leave the secondmate's dispatch-cap untouched"
  [ "$(cat "$second/config/codex-lane-cap")" = 9 ] \
    || fail "an uninspectable primary source must leave the secondmate's codex-lane-cap untouched"
  pass "an uninspectable primary source refuses to converge dispatch-cap and codex-lane-cap"
}
test_unreadable_primary_source_reports_error_and_fails

test_nonregular_destination_refuses_copy() {
  local rec primary second report rc
  rec=$(new_home_pair nonregular_dest)
  primary=${rec%%|*}
  second=${rec#*|}
  printf '2\n' > "$primary/config/dispatch-cap"
  printf '1\n' > "$primary/config/codex-lane-cap"
  mkdir -p "$second/config/dispatch-cap" "$second/config/codex-lane-cap"
  report="$TMP_ROOT/nonregular_dest.report"

  rc=0
  FM_CONFIG_INHERIT_REPORT="$report" \
    propagate_inheritable_config "$primary/config" "$second/config" \
    2>/dev/null || rc=$?

  [ "$rc" = 1 ] || fail "a non-regular destination must fail propagation with rc=1 (got $rc)"
  grep -q $'^dispatch-cap\terror\t' "$report" \
    || fail "a non-regular config/dispatch-cap destination must report error"
  grep -q $'^codex-lane-cap\terror\t' "$report" \
    || fail "a non-regular config/codex-lane-cap destination must report error"
  [ -d "$second/config/dispatch-cap" ] \
    || fail "a non-regular config/dispatch-cap destination must not be replaced"
  [ -d "$second/config/codex-lane-cap" ] \
    || fail "a non-regular config/codex-lane-cap destination must not be replaced"
  pass "a non-regular destination refuses the dispatch-cap and codex-lane-cap copy"
}
test_nonregular_destination_refuses_copy

echo "PASS fm-config-inherit-lane-caps.test.sh"
