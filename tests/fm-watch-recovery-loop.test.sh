#!/usr/bin/env bash
# Pin the Pi/OpenCode recovery-loop fix: one announcement per generation, and a
# handling successor that keeps supervising instead of going blind.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox" \
    "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

# T1: a lost --handling-delivered handshake must not re-announce forever.
# The real Pi extension drives the real arm/watcher, with only the handshake
# RPC forced to fail. After the first recovery follow-up, wait past the old
# ~52s loop period so a regression would emit a second follow-up.
test_unacknowledged_recovery_is_announced_once_per_generation() {
  local repo home plugin fakebin out status lock_pid messages
  repo="$TMP_ROOT/t1-root"
  home="$TMP_ROOT/t1-home"
  fakebin="$TMP_ROOT/t1-fakebin"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  exit 1
fi
export FM_ROOT_OVERRIDE="$ROOT"
export PATH="$fakebin:\$PATH"
exec "$ROOT/bin/fm-watch-arm.sh" "\$@"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  : > "$home/state/seed.meta"
  printf 'pending:downtime:seed.1.aaa\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"
  printf '%s\t1\tcheck\tseed\tcheck: seed recovery\n' "$(date +%s)" > "$home/state/.wake-queue"
  out=$(
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(String(message));
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
await tool.execute("tool-call-t1", {}, undefined, undefined, {});
const deadline = Date.now() + 75000;
let firstAt = 0;
while (Date.now() < deadline) {
  const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
  if (rearm.length > 1) {
    throw new Error(`unbounded recovery loop: ${rearm.length} rearm-resurface follow-ups`);
  }
  if (rearm.length === 1 && firstAt === 0) firstAt = Date.now();
  if (firstAt && Date.now() - firstAt >= 55000) break;
  await new Promise((resolve) => setTimeout(resolve, 200));
}
const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
if (rearm.length !== 1) {
  throw new Error(`expected exactly one recovery follow-up, got ${rearm.length}: ${prompts.join(" || ")}`);
}
const lockPid = existsSync(`${process.env.FM_HOME}/state/.watch.lock/pid`)
  ? readFileSync(`${process.env.FM_HOME}/state/.watch.lock/pid`, "utf8").trim()
  : "";
if (!/^[0-9]+$/.test(lockPid)) throw new Error("successor watcher lock pid missing");
try {
  process.kill(Number(lockPid), 0);
} catch {
  throw new Error(`successor watcher ${lockPid} is not alive`);
}
const marker = readFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "utf8").trim();
if (!marker.startsWith("announced:") && !marker.startsWith("pending:")) {
  throw new Error(`successor did not keep a live recovery episode: ${marker}`);
}
console.log(`T1_MESSAGES=${rearm.length}`);
console.log(`T1_LOCK_PID=${lockPid}`);
console.log(`T1_MARKER=${marker}`);
process.exit(0);
EOF
  )
  status=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '%s\n' "$out"
  fi
  lock_pid=$(sed -n 's/^T1_LOCK_PID=//p' <<<"$out" | tail -1)
  messages=$(sed -n 's/^T1_MESSAGES=//p' <<<"$out" | tail -1)
  if [ -n "$lock_pid" ]; then
    kill -TERM "$lock_pid" 2>/dev/null || true
  fi
  expect_code 0 "$status" "an unacknowledged recovery must be announced at most once per generation: $out"
  [ "$messages" = 1 ] || fail "T1 did not report a single recovery follow-up: $out"
  pass "unacknowledged recovery is announced at most once per generation and the successor stays alive"
}

# T2: a handling successor must enter its poll loop and surface a real crew
# event within a bounded startup-and-poll budget instead of sitting in a
# pre-loop wait that refreshes the liveness beacon and then exits with a
# synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 20 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within the bounded startup-and-poll budget (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

# Start one fresh (non-successor) watcher cycle, the shape every Claude Stop
# auto-arm produces after the previous cycle closed on its wake.
start_fresh_watcher() {  # <dir> <out>
  local dir=$1 out=$2
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_REARM_RESURFACE_LIMIT=2 "$WATCH" > "$out" 2>&1 &
  FRESH_PID=$!
}

streak_count() {  # <state>
  sed -n '1s/.*\t//p' "$1/.rearm-resurface-streak" 2>/dev/null
}

# Expect this cycle to close on exactly <reason-prefix>.
expect_resurface_close() {  # <dir> <out> <reason-prefix> <label>
  local dir=$1 out=$2 prefix=$3 label=$4 status
  start_fresh_watcher "$dir" "$out"
  wait_for_exit "$FRESH_PID" 150
  status=$?
  [ "$status" -ne 124 ] || fail "$label: fresh watcher did not resurface the undrained queue: $(cat "$out")"
  grep -qF -- "$prefix" "$out" || fail "$label: expected '$prefix', got: $(cat "$out")"
}

# Expect this cycle to stay quiet but live: the streak advances past the bound,
# nothing is delivered, and the watcher keeps supervising until stopped.
expect_resurface_quiet() {  # <dir> <out> <expected-count> <label>
  local dir=$1 out=$2 want=$3 label=$4 i=0
  start_fresh_watcher "$dir" "$out"
  while [ "$i" -lt 150 ] && [ "$(streak_count "$dir/state")" != "$want" ]; do
    is_live_non_zombie "$FRESH_PID" || break
    sleep 0.1
    i=$((i + 1))
  done
  sleep 1.5
  if ! is_live_non_zombie "$FRESH_PID"; then
    wait "$FRESH_PID" 2>/dev/null || true
    fail "$label: suppressed watcher did not stay live to keep supervising: $(cat "$out")"
  fi
  kill -TERM "$FRESH_PID" 2>/dev/null || true
  wait_for_exit "$FRESH_PID" 50 >/dev/null 2>&1 || true
  [ "$(streak_count "$dir/state")" = "$want" ] \
    || fail "$label: resurface streak is $(streak_count "$dir/state"), expected $want"
  ! grep -qF 'check: rearm-resurface' "$out" \
    || fail "$label: bounded resurface still forced a wake: $(cat "$out")"
}

# T3: an unacknowledged wake the model cannot drain (a denied or failing
# drain) must not force a turn at every Stop without bound. With limit 2 the
# ordinary reason is delivered twice, a distinct stalled escalation once, and
# later fresh cycles stay quiet and live. The queued row is never dropped, and
# a drain or a new wake restores ordinary delivery.
test_undrainable_queue_resurface_is_bounded() {
  local dir state queue_before
  dir=$(make_case undrainable-resurface)
  state="$dir/state"
  mkdir -p "$dir/home/data"
  append_wake "$state" check seed 'check: seed wake the model cannot drain' \
    || fail "could not seed the durable wake"
  queue_before=$(cat "$state/.wake-queue")

  expect_resurface_close "$dir" "$dir/c1.out" 'check: rearm-resurface' "cycle 1"
  expect_resurface_close "$dir" "$dir/c2.out" 'check: rearm-resurface' "cycle 2"
  ! grep -qF 'stalled' "$dir/c2.out" || fail "cycle 2 escalated before the bound: $(cat "$dir/c2.out")"
  expect_resurface_close "$dir" "$dir/c3.out" 'check: rearm-resurface stalled' "cycle 3"
  expect_resurface_quiet "$dir" "$dir/c4.out" 4 "cycle 4"
  expect_resurface_quiet "$dir" "$dir/c5.out" 5 "cycle 5"
  [ "$(cat "$state/.wake-queue")" = "$queue_before" ] \
    || fail "bounded resurfacing dropped or rewrote the durable wake"
  pass "an undrainable queued wake resurfaces a bounded number of times, escalates once, then stays quiet and live"

  # A presentation-only drain neither consumes the row nor changes the queue,
  # so it must not reset the streak on its own: only an actual acknowledgement,
  # a new wake, or a session restart does.
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    > "$dir/drain.out" 2> "$dir/drain.err" || fail "drain failed: $(cat "$dir/drain.err")"
  [ "$(cat "$state/.wake-queue")" = "$queue_before" ] \
    || fail "a presentation-only drain rewrote the durable queue"
  expect_resurface_quiet "$dir" "$dir/c6.out" 6 "after presentation-only drain"

  # Progress by acknowledgement: run the exact WAKE_ACK_REQUIRED command the
  # drain printed, which actually consumes the presented row and changes the
  # queue's fingerprint.
  ack_through=$(sed -n 's/.*--ack-through \([0-9]\{1,\}\) --recovery-generation.*/\1/p' "$dir/drain.err" | tail -1)
  ack_gen=$(sed -n 's/.*--recovery-generation \([^[:space:]]\{1,\}\)$/\1/p' "$dir/drain.err" | tail -1)
  [ -n "$ack_through" ] && [ -n "$ack_gen" ] \
    || fail "could not parse the WAKE_ACK_REQUIRED command: $(cat "$dir/drain.err")"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$ack_through" --recovery-generation "$ack_gen" \
    > "$dir/ack.out" 2> "$dir/ack.err" || fail "acknowledgement failed: $(cat "$dir/ack.err")"
  [ ! -e "$state/.rearm-resurface-streak" ] \
    || fail "an acknowledgement left the resurface streak record behind"
  append_wake "$state" check second 'check: a new wake arrived' || fail "could not append a new wake"
  expect_resurface_close "$dir" "$dir/c7.out" 'check: rearm-resurface' "after acknowledgement"
  ! grep -qF 'stalled' "$dir/c7.out" || fail "an acknowledgement did not reset the resurface bound: $(cat "$dir/c7.out")"
  [ "$(streak_count "$state")" = 1 ] || fail "an acknowledgement did not restart the streak at 1"

  # Progress by a new wake: exhaust the bound again, then a new row resets it.
  expect_resurface_close "$dir" "$dir/c8.out" 'check: rearm-resurface' "post-ack cycle 2"
  expect_resurface_close "$dir" "$dir/c9.out" 'check: rearm-resurface stalled' "post-ack cycle 3"
  append_wake "$state" check third 'check: another new wake arrived' || fail "could not append another new wake"
  expect_resurface_close "$dir" "$dir/c10.out" 'check: rearm-resurface' "after another new wake"
  ! grep -qF 'stalled' "$dir/c10.out" || fail "a new wake did not reset the resurface bound: $(cat "$dir/c10.out")"

  # Progress by session restart: a new session-lock owner resets the streak.
  expect_resurface_close "$dir" "$dir/c11.out" 'check: rearm-resurface' "post-wake cycle 2"
  expect_resurface_close "$dir" "$dir/c12.out" 'check: rearm-resurface stalled' "post-wake cycle 3"
  printf '%s\n' "$$" > "$state/.lock"
  expect_resurface_close "$dir" "$dir/c13.out" 'check: rearm-resurface' "after session restart"
  ! grep -qF 'stalled' "$dir/c13.out" || fail "a session restart did not reset the resurface bound: $(cat "$dir/c13.out")"
  pass "an acknowledgement, a new wake, or a session restart restores ordinary resurface delivery, but a presentation-only drain does not"
}

test_handling_successor_does_not_go_blind
test_unacknowledged_recovery_is_announced_once_per_generation
test_undrainable_queue_resurface_is_bounded
