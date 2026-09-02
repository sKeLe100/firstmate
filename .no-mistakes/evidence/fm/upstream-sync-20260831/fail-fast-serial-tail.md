# fail-fast honors the unproven serial tail (bin/fm-test-run.sh)

Fixture: plain `--changed` selects two proven-concurrent scripts (one fails)
plus one unproven script that lands in the serial remainder.

## BEFORE (runner at ff99587^) - the unproven tail still ran
```
  FM_TEST_BEGIN 2026-09-02T11:27:02Z tests/fm-daemon.test.sh family=watcher-wake-lock expected_gate_skip=none
  FM_TEST_BEGIN 2026-09-02T11:27:02Z tests/fm-pi-watch-extension.test.sh family=watcher-wake-lock expected_gate_skip=none
  FM_TEST_BEGIN 2026-09-02T11:27:02Z tests/fm-backend-herdr-smoke.test.sh family=real-herdr-gated expected_gate_skip=herdr
  FM_TEST_SUMMARY total=3 failed=1 skipped_gate=0 duration_ms=958
  TAIL_RAN=yes
```

## AFTER (runner at 85ea153) - the tail is never scheduled
```
  FM_TEST_BEGIN 2026-09-02T11:27:03Z tests/fm-daemon.test.sh family=watcher-wake-lock expected_gate_skip=none
  FM_TEST_BEGIN 2026-09-02T11:27:03Z tests/fm-pi-watch-extension.test.sh family=watcher-wake-lock expected_gate_skip=none
  fm-test-run: fail-fast: not scheduling remaining scripts after a failure
  FM_TEST_SUMMARY total=2 failed=1 skipped_gate=0 duration_ms=772
  TAIL_RAN=no
```
