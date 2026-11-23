#!/usr/bin/env bash
# Behavior tests for bin/fm-pc02-wake.sh: status never sends a packet, ensure
# wakes a sleeping host and then succeeds, an unreachable host returns asleep,
# discovery caches the Wi-Fi MAC and LAN broadcast, and an unmanaged host is a
# no-op. A fake SSH and a fake python3 keep the cases off any real host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pc02-wake.sh"
TMP_ROOT=$(fm_test_tmproot fm-pc02-wake)
fakebin=$(fm_fakebin "$TMP_ROOT/fake")
CONFIG="$TMP_ROOT/pc02-wake.conf"
export FM_PC02_WAKE_CONFIG="$CONFIG"
export FM_TEST_SSH_LOG="$TMP_ROOT/ssh.log"
export FM_TEST_SEND_LOG="$TMP_ROOT/send.log"
export FM_TEST_AWAKE_FLAG="$TMP_ROOT/awake"
export FM_TEST_DISCOVER_INFO='A0-E7-0B-3D-00-D6|10.0.0.173|100.67.55.77'
REAL_PYTHON=$(command -v python3)

cat >"$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_SSH_LOG"
# discover streams a bash script on stdin and expects one info line.
if [ "${*: -2}" = "bash -s" ]; then
  cat >/dev/null
  printf '%s\n' "$FM_TEST_DISCOVER_INFO"
  exit 0
fi
[ -e "$FM_TEST_AWAKE_FLAG" ]
SH

cat >"$fakebin/python3" <<'SH'
#!/usr/bin/env bash
if [ "${2:-}" = "A0-E7-0B-3D-00-D6" ]; then
  printf 'port=%s\ncount=%s\n' "$3" "$4" >> "$FM_TEST_SEND_LOG"
  shift 4
  printf '%s\n' "$@" >> "$FM_TEST_SEND_LOG"
  [ -n "${FM_TEST_WAKE_FAILS:-}" ] || : > "$FM_TEST_AWAKE_FLAG"
  exit 0
fi
exec "$FM_TEST_REAL_PYTHON" "$@"
SH

cat >"$fakebin/ip" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'route get'*) printf '10.0.0.173 via 10.0.0.1 dev eth1 src 10.0.0.147\n' ;;
  *'addr show'*) printf '3: eth1    inet 10.0.0.147/24 brd 10.0.0.255 scope global eth1\n' ;;
esac
SH

cat >"$fakebin/ping" <<'SH'
#!/usr/bin/env bash
echo "ping must never be used" >&2
exit 99
SH
chmod +x "$fakebin"/*
export FM_TEST_REAL_PYTHON="$REAL_PYTHON"
export PATH="$fakebin:$PATH"

reset() {
  rm -f "$FM_TEST_SSH_LOG" "$FM_TEST_SEND_LOG" "$FM_TEST_AWAKE_FLAG" "$CONFIG"
}
write_config() {
  cat >"$CONFIG" <<EOF
host=pc02
mac=A0-E7-0B-3D-00-D6
broadcast=10.0.0.255
lan_ip=10.0.0.173
tailnet_ip=100.67.55.77
EOF
}

reset
write_config
: >"$FM_TEST_AWAKE_FLAG"
out=$(bash "$SCRIPT" status)
[ "$out" = awake ] || fail "an answering host must read awake: $out"
[ ! -e "$FM_TEST_SEND_LOG" ] || fail "status must never send a magic packet"
pass "status reads an answering host awake without sending"

reset
write_config
out=$(bash "$SCRIPT" status)
[ "$out" = asleep ] || fail "a silent host must read asleep: $out"
[ ! -e "$FM_TEST_SEND_LOG" ] || fail "status must never send a magic packet"
pass "status reads a silent host asleep without sending"

reset
write_config
out=$(bash "$SCRIPT" status --if-managed --quiet)
[ "$out" = asleep ] || fail "status --quiet must still print asleep: $out"
: >"$FM_TEST_AWAKE_FLAG"
out=$(bash "$SCRIPT" status --if-managed --quiet)
[ "$out" = awake ] || fail "status --quiet must still print awake: $out"
out=$(bash "$SCRIPT" status --host pc02.bad --if-managed --quiet)
[ "$out" = unmanaged ] || fail "status --quiet must still print unmanaged: $out"
pass "status --quiet keeps printing its one word"

reset
write_config
out=$(bash "$SCRIPT" ensure --quiet) || fail "ensure must succeed after the fake magic packet wakes the host"
[ "$out" = '' ] || fail "ensure --quiet must print nothing: $out"
grep -Fxq 'port=9' "$FM_TEST_SEND_LOG" || fail "ensure did not send to the configured port"
grep -Fxq 'count=3' "$FM_TEST_SEND_LOG" || fail "ensure did not send the configured packet count"
grep -Fxq '10.0.0.255' "$FM_TEST_SEND_LOG" || fail "ensure did not target the LAN broadcast"
grep -Fxq '10.0.0.173' "$FM_TEST_SEND_LOG" || fail "ensure did not also target the last-known LAN address"
pass "ensure sends the magic packet and returns once SSH answers"

reset
write_config
out=$(FM_TEST_WAKE_FAILS=1 bash "$SCRIPT" ensure --timeout 1)
rc=$?
[ "$rc" -eq 4 ] || fail "ensure must return 4 when the host never answers, got $rc"
[ "$out" = asleep ] || fail "ensure must print asleep on timeout: $out"
pass "ensure reports asleep when a wake does not answer"

reset
write_config
out=$(bash "$SCRIPT" status --host pc02.bad --if-managed)
[ "$out" = unmanaged ] || fail "an unmanaged host must read unmanaged: $out"
[ ! -e "$FM_TEST_SSH_LOG" ] || fail "an unmanaged host must not be probed"
pass "an unmanaged host is a no-op"

reset
: >"$FM_TEST_AWAKE_FLAG"
out=$(bash "$SCRIPT" discover --quiet)
[ -z "$out" ] || fail "discover should be quiet on success by default"
grep -Fxq 'host=pc02' "$CONFIG" || fail "discover did not record the host"
grep -Fxq 'mac=A0-E7-0B-3D-00-D6' "$CONFIG" || fail "discover did not record the Wi-Fi MAC"
grep -Fxq 'broadcast=10.0.0.255' "$CONFIG" || fail "discover did not derive the LAN broadcast"
grep -Fxq 'lan_ip=10.0.0.173' "$CONFIG" || fail "discover did not record the LAN address"
grep -Fxq 'tailnet_ip=100.67.55.77' "$CONFIG" || fail "discover did not record the tailnet address"
pass "discover caches the Wi-Fi MAC, LAN address, and broadcast"

reset
write_config
(
  . "$ROOT/bin/fm-secondmate-liveness-lib.sh"
  out=$(fm_sm_live_remote_reason pc02 "probe failed")
  case "$out" in *'asleep (wakeable)'*) ;; *) echo "liveness must report an asleep host as wakeable: $out" >&2; exit 1 ;; esac
  : >"$FM_TEST_AWAKE_FLAG"
  out=$(fm_sm_live_remote_reason pc02 "probe failed")
  case "$out" in *'asleep (wakeable)'*) echo "an awake host must not read asleep: $out" >&2; exit 1 ;; esac
) || fail "secondmate liveness must classify a silent managed host as asleep (wakeable)"
pass "secondmate liveness reports a silent managed host as asleep, wakeable"

echo "# all fm-pc02-wake tests passed"
