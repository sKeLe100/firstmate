#!/usr/bin/env bash
# Behavior test for tests/lib.sh's fixture primary-watchdog reaping: a
# fm-primary-watchdog.sh loop whose FM_HOME is inside a registered fixture root
# is found and stopped by fm_test_cleanup, while one outside every fixture root
# (the real home's, a sibling run's) is never touched.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root=$(fm_test_tmproot fm-wdreap)
outside=$(mktemp -d "$(fm_test_tmpdir)/fm-wdreap-outside.XXXXXX") || exit 1
mkdir -p "$root/home" "$root/bin" "$outside/bin"
# Stand-ins named like the real script so the command line matches `run`.
for d in "$root/bin" "$outside/bin"; do
  printf '#!/usr/bin/env bash\nsleep 60\n' > "$d/fm-primary-watchdog.sh"
  chmod +x "$d/fm-primary-watchdog.sh"
done
FM_HOME="$root/home" setsid "$root/bin/fm-primary-watchdog.sh" run </dev/null >/dev/null 2>&1 &
FM_HOME="$outside" setsid "$outside/bin/fm-primary-watchdog.sh" run </dev/null >/dev/null 2>&1 &
sleep 0.5
OUT_PID=$(pgrep -f "$outside/bin/fm-primary-watchdog.sh" | head -n 1)
trap 'kill "$OUT_PID" 2>/dev/null; rm -rf "$outside"; fm_test_cleanup' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

[ -n "$(fm_test_fixture_watchdog_pids)" ] || fail "fixture watchdog was not detected"
case "$(fm_test_fixture_watchdog_pids)" in *"$OUT_PID"*) fail "outside watchdog was matched" ;; esac
fm_test_reap_fixture_watchdogs
[ -z "$(fm_test_fixture_watchdog_pids)" ] || fail "fixture watchdog survived the reap"
kill -0 "$OUT_PID" 2>/dev/null || fail "reap touched a watchdog outside the fixture roots"
printf 'ok - fixture watchdogs are reaped by FM_HOME scope only\n'
