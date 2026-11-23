#!/usr/bin/env bash
# Behavior tests for the remote-sleep presence gate in
# bin/fm-pc02-sleep-arming.sh. A refused test must exit before any SSH call,
# and only an explicit --attended may override either refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pc02-sleep-arming.sh"
TMP_ROOT=$(fm_test_tmproot fm-pc02-sleep-arming)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
fakebin=$(fm_fakebin "$TMP_ROOT/fake")
export FM_STATE_OVERRIDE="$STATE"
export FM_TEST_SSH_LOG="$TMP_ROOT/ssh.log"
export FM_TEST_ET_HOUR=12
export FM_TEST_DATE_FAILS=0
export PATH="$fakebin:$PATH"

cat >"$fakebin/date" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "+%H" ]; then
  [ "$FM_TEST_DATE_FAILS" = 0 ] || exit 1
  printf '%s\n' "$FM_TEST_ET_HOUR"
  exit 0
fi
exec /bin/date "$@"
SH
cat >"$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_SSH_LOG"
echo "ssh must not be called for a refused sleep test" >&2
exit 99
SH
chmod +x "$fakebin"/*

run_gate() {
  FM_TEST_ET_HOUR=$1 bash "$SCRIPT" check-attendance "${@:2}" 2>"$TMP_ROOT/err"
}

rm -f "$STATE/.afk" "$FM_TEST_SSH_LOG"
out=$(run_gate 12)
rc=$?
[ "$rc" -eq 0 ] || fail "daytime with no away record must be allowed, got $rc: $(cat "$TMP_ROOT/err")"
[ "$out" = 'attended: allowed' ] || fail "allowed gate must print attended: allowed, got '$out'"
pass "daytime with no away record is allowed"

: >"$STATE/.afk"
out=$(run_gate 12)
rc=$?
[ "$rc" -eq 3 ] || fail "an away record must refuse the gate, got $rc"
grep -q 'state/.afk' "$TMP_ROOT/err" || fail "the refusal must name state/.afk"
grep -q -- '--attended' "$TMP_ROOT/err" || fail "the refusal must name --attended"
[ ! -e "$FM_TEST_SSH_LOG" ] || fail "a refused gate must not call ssh"
pass "an away record refuses the gate before any host access"

out=$(run_gate 12 --attended)
rc=$?
[ "$rc" -eq 0 ] || fail "--attended must override the away record, got $rc: $(cat "$TMP_ROOT/err")"
[ "$out" = 'attended: allowed' ] || fail "--attended must print attended: allowed, got '$out'"
rm -f "$STATE/.afk"
pass "--attended overrides the away record"

out=$(run_gate 23)
rc=$?
[ "$rc" -eq 3 ] || fail "quiet hours must refuse the gate, got $rc"
grep -q 'quiet hours' "$TMP_ROOT/err" || fail "the refusal must name quiet hours"
grep -q '22:00-08:00' "$TMP_ROOT/err" || fail "the refusal must name the quiet window"
pass "quiet hours refuse the gate"

out=$(run_gate 5)
rc=$?
[ "$rc" -eq 3 ] || fail "an early-morning hour must refuse the gate, got $rc"
pass "the early-morning half of the quiet window refuses"

out=$(run_gate 23 --attended)
rc=$?
[ "$rc" -eq 0 ] || fail "--attended must override quiet hours, got $rc: $(cat "$TMP_ROOT/err")"
pass "--attended overrides quiet hours"

out=$(FM_TEST_DATE_FAILS=1 run_gate 12)
rc=$?
[ "$rc" -eq 3 ] || fail "an unreadable ET hour must fail closed, got $rc"
grep -q 'cannot determine' "$TMP_ROOT/err" || fail "an unreadable hour must say why it refused"
pass "an unreadable ET hour fails closed"

rm -f "$FM_TEST_SSH_LOG"
: >"$STATE/.afk"
out=$(FM_TEST_ET_HOUR=12 bash "$SCRIPT" test-sleep 2>"$TMP_ROOT/err")
rc=$?
[ "$rc" -eq 3 ] || fail "test-sleep must refuse an away record with 3, got $rc"
[ ! -e "$FM_TEST_SSH_LOG" ] || fail "a refused test-sleep must not reach the host"
rm -f "$STATE/.afk"

out=$(FM_TEST_ET_HOUR=23 bash "$SCRIPT" test-sleep 2>"$TMP_ROOT/err")
rc=$?
[ "$rc" -eq 3 ] || fail "test-sleep must refuse during quiet hours with 3, got $rc"
[ ! -e "$FM_TEST_SSH_LOG" ] || fail "a quiet-hours test-sleep must not reach the host"
pass "test-sleep refuses before any host access"

echo "# all fm-pc02-sleep-arming tests passed"
