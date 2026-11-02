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

# --- runner-style kill: TERM mid-run, then SIGKILL + start-up sweep ----------
# A child "suite" sources the library, registers a fixture root, and starts a
# watchdog stand-in under it, then idles. TERM (what bin/fm-test-run.sh sends
# at a per-script timeout) must leave zero loops for that root. SIGKILL skips
# every trap, so it orphans the loop; the next run's fm_test_reap_orphans must
# reap it, and must leave a live owner's loop alone.
child="$outside/child-suite.sh"
cat > "$child" <<EOF
#!/usr/bin/env bash
. "$ROOT/tests/lib.sh"
r=\$(fm_test_tmproot fm-wdreap-child)
mkdir -p "\$r/home" "\$r/bin"
printf '#!/usr/bin/env bash\nsleep 60\n' > "\$r/bin/fm-primary-watchdog.sh"
chmod +x "\$r/bin/fm-primary-watchdog.sh"
FM_HOME="\$r/home" setsid "\$r/bin/fm-primary-watchdog.sh" run </dev/null >/dev/null 2>&1 &
printf '%s\n' "\$r" > "$outside/child-root"
while :; do sleep 1; done
EOF
chmod +x "$child"
child_loops() {  # <root>: pids of watchdog stand-ins whose script lives under root
  pgrep -f "$1/bin/fm-primary-watchdog.sh" 2>/dev/null
}
start_child() {
  rm -f "$outside/child-root"
  FM_TEST_SKIP_ORPHAN_REAP=1 bash "$child" >/dev/null 2>&1 &
  CHILD=$!
  local i=0
  while [ ! -s "$outside/child-root" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  sleep 0.3
  CHILD_ROOT=$(cat "$outside/child-root")
}

start_child
[ -n "$(child_loops "$CHILD_ROOT")" ] || fail "child suite's watchdog did not start"
kill -TERM "$CHILD"; wait "$CHILD" 2>/dev/null
sleep 0.5
[ -z "$(child_loops "$CHILD_ROOT")" ] || fail "TERM left a fixture watchdog alive"
printf 'ok - TERM mid-run leaves no fixture watchdog\n'

start_child
LIVE_ROOT=$CHILD_ROOT; LIVE_CHILD=$CHILD
start_child
kill -KILL "$CHILD"; wait "$CHILD" 2>/dev/null
sleep 0.3
[ -n "$(child_loops "$CHILD_ROOT")" ] || fail "SIGKILL unexpectedly left no watchdog (nothing to sweep)"
fm_test_reap_orphans
sleep 0.5
[ -z "$(child_loops "$CHILD_ROOT")" ] || fail "start-up sweep did not reap the SIGKILLed run's watchdog"
[ -n "$(child_loops "$LIVE_ROOT")" ] || fail "start-up sweep reaped a live owner's watchdog"
kill -TERM "$LIVE_CHILD"; wait "$LIVE_CHILD" 2>/dev/null
printf 'ok - start-up sweep reaps a SIGKILLed run'"'"'s watchdog and spares a live owner'"'"'s\n'
