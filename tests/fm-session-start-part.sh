#!/usr/bin/env bash
# Content-preserving upstream test block, sourced by fm-session-start.test.sh.

test_perl_timeout_fallback_reports_signal_death_nonzero() {
  local toolbin cmd rc=0
  command -v perl >/dev/null 2>&1 || { echo "skip: perl not found (this case pins the perl mechanism only)"; return 0; }
  toolbin=$(mktemp -d "${TMPDIR:-/tmp}/fm-perl-timeout.XXXXXX")
  for cmd in bash perl sleep kill cat rm mktemp; do
    command -v "$cmd" >/dev/null 2>&1 && ln -s "$(command -v "$cmd")" "$toolbin/$cmd"
  done
  PATH="$toolbin" bash -c '
    . "$1/bin/fm-timeout-lib.sh"
    [ "$(fm_timeout_mechanism)" = perl ] || { echo "mechanism: $(fm_timeout_mechanism)" >&2; exit 99; }
    fm_run_timed 5 bash -c "kill -KILL \$\$"
  ' _ "$ROOT" || rc=$?
  rm -rf "$toolbin"
  expect_code 137 "$rc" "the perl timeout fallback did not report a SIGKILLed child as 128+9"

  pass "the perl timeout fallback reports a signal death as a nonzero status"
}

test_abnormal_digest_death_banners_and_exits_zero() {
  local rec root home fakebin out status=0
  [ -r /proc/self/stat ] || { echo "skip: /proc not readable (the digest-death shape needs process ancestry)"; return 0; }
  rec=$(new_world digest-death-banner)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  # Replace the harness ps with one that TERMs the digest process itself when
  # fm-lock.sh invokes it: the shape where the digest child dies mid-stage
  # from something other than its runtime bound, which the parent used to
  # swallow silently (no banner, exit 0, rest of the digest gone).
  # ps sits below fm-lock.sh below the digest bash, so walk /proc upward.
  # Flattened cmdline matching alone is useless: timeout's bash -c inner shell
  # and the timeout wrapper carry the script path as an ARGV element, and the
  # lock stage's own command substitution leaves a subshell whose argv is
  # still `fm-session-start.sh` - only the topmost match is the digest bash
  # itself. That digest child is the topmost ancestor whose ENVIRON carries
  # FM_SESSION_START_STAGE_FILE: the parent wrapper mktemps the file and hands
  # it over with env (which never keeps it for itself), the bash -c inner
  # shell and timeout sit BELOW env, and the parent wrapper never holds it -
  # so the env marker stops the walk above the digest child and below the
  # wrapper whose death would skip the banner entirely. Kill that topmost
  # marker carrier: the digest bash whose death the parent must banner.
  mv "$fakebin/ps" "$fakebin/ps.real"
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
case "\$(tr '\\0' ' ' < /proc/\$PPID/cmdline 2>/dev/null)" in
  *fm-lock.sh*)
    pid=\$PPID
    target=
    matched=0
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      [ -n "\$pid" ] && [ "\$pid" != 1 ] || break
      if tr '\\0' '\\n' < /proc/\$pid/environ 2>/dev/null | grep -q '^FM_SESSION_START_STAGE_FILE=' \
        && case "\$(tr '\\0' ' ' < /proc/\$pid/cmdline 2>/dev/null)" in *fm-session-start.sh*) true ;; *) false ;; esac; then
        target=\$pid
        matched=1
      elif [ "\$matched" -eq 1 ]; then
        break
      fi
      pid=\$(sed 's/^[^)]*) //' /proc/\$pid/stat 2>/dev/null | awk '{print \$2}')
    done
    [ -n "\$target" ] && kill -TERM "\$target" 2>/dev/null
    ;;
esac
exec "$fakebin/ps.real" "\$@"
SH
  chmod +x "$fakebin/ps"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?

  expect_code 0 "$status" "a digest child that died mid-stage must still let the session open (parent exits 0)"
  assert_contains "$out" \
    "STARTUP TRUNCATED - SESSION START DIED UNEXPECTEDLY (exit 143, not its runtime bound)" \
    "a digest child killed mid-stage did not name its abnormal death"
  assert_contains "$out" 'stopped during the "lock" stage' \
    "the abnormal-death banner did not name the stage that never finished"
  assert_contains "$out" \
    "wake-queue supervision-instructions read-once fleet-state network-checks context next-step" \
    "the abnormal-death banner did not list every stage that never ran"
  assert_not_contains "$out" "RUNTIME BOUND" \
    "an abnormal death was misreported as the runtime bound firing"
  assert_contains "$out" "report the exit status and the stage" \
    "the abnormal-death banner did not tell the reader to report the exit status"
  assert_not_contains "$out" "raise FM_SESSION_START_TIMEOUT" \
    "the abnormal-death banner advised raising a bound that did not fire"
  assert_not_contains "$out" "NEXT STEP" \
    "a digest that died mid-stage claimed to have reached its closing reminder"
  assert_absent "$home/state/.session-start-complete" \
    "a digest that died mid-stage recorded itself as complete"

  pass "a digest child killed mid-stage is bannered by the parent, which still exits 0"
}

# --- composition: real scripts run, not reimplemented ------------------------

test_composition_invokes_real_scripts() {
  local rec root home fakebin out
  rec=$(new_world composition)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  rm -f "$fakebin/node"

  printf 'needs-decision: pick a library\n' > "$home/state/task-z.status"
  append_wake "$home/state" signal task-z.status "needs-decision: pick a library"

  out=$(run_session_start "$home" "$root" "$fakebin:$(fm_test_base_path_sans "$BASE_PATH" node)")

  # fm-lock.sh's own exact success text.
  assert_contains "$out" "lock acquired: harness pid" "fm-lock.sh's real output did not appear (composition, not reimplementation)"
  # fm-bootstrap.sh's own exact MISSING-tool line format.
  assert_contains "$out" "MISSING: node (install:" "fm-bootstrap.sh's real detect line did not appear verbatim"
  # fm-wake-drain.sh's real drained record (raw tab-separated queue line).
  assert_contains "$out" "$(printf 'signal\ttask-z.status\tneeds-decision: pick a library')" "fm-wake-drain.sh's real drained record did not appear"
  assert_contains "$out" "wake annotation: latest wake-EVENT observed at drain, not current state: task-z.status: needs-decision: pick a library" "fm-session-start.sh did not preserve the drain's separate annotation line"

  pass "fm-session-start.sh composes the real fm-lock.sh, fm-bootstrap.sh, and fm-wake-drain.sh output verbatim"
}

test_branch_outcome_replay_respects_captain_barrier_and_lease_sweep() {
  local rec root home fakebin out
  rec=$(new_world branch-recovery)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi

  # A crash window the locked start must preserve: the supervision branch
  # stored a leading routine row and a captain row that never reached Pi, plus one lease whose
  # supervising process died and one still held by a live process.
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-a --verdict routine --summary 'worker recovered automatically' >/dev/null \
    || fail "could not seed the unread routine branch outcome"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-b --verdict captain --summary 'PR https://example.com/pr/b checks green' >/dev/null \
    || fail "could not seed the unread branch outcome"
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-live --actor branch \
    || fail "could not seed the live lease"

  out=$(run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):" \
    "locked start did not replay the leading routine branch outcome"
  assert_contains "$out" "worker recovered automatically" "replayed routine outcome lost its content"
  assert_not_contains "$out" "https://example.com/pr/b" "locked start crossed the captain delivery barrier"
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread)" \
    "https://example.com/pr/b" "locked start marked the unrendered captain outcome read"
  [ "$(cat "$home/state/.branch-outcomes-cursor")" = 1 ] || fail "locked start advanced past the captain row"
  [ ! -e "$home/state/.lease-task-dead" ] || fail "locked start left a provably dead lease in place"
  [ -e "$home/state/.lease-task-live" ] || fail "locked start swept a live lease"

  # Routine replay is one-shot, while the captain row remains held for Pi's
  # sequence-keyed visible-entry reconciliation.
  out=$(run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  case "$out" in
    *"BRANCH OUTCOMES"*) fail "second start re-presented already-replayed branch outcomes" ;;
  esac
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread)" \
    "https://example.com/pr/b" "second start consumed the captain row without a Pi entry"
  pass "locked Pi session start replays leading routine outcomes, preserves the captain barrier, and sweeps only dead leases"
}

test_non_pi_session_start_leaves_branch_state_untouched() {
  local rec root home fakebin out
  rec=$(new_world non-pi-branch-recovery)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  # A Claude home runs the supervision host by default and then presents its
  # outcomes; this case pins a home that does not run it.
  : > "$home/config/supervision-host-off"

  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-b --verdict captain --summary 'unread Pi branch outcome' >/dev/null \
    || fail "could not seed the non-Pi unread branch outcome"
  rm -f "$home/state/.branch-outcomes-cursor"
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  case "$out" in
    *"BRANCH OUTCOMES"*|*"unread Pi branch outcome"*) fail "non-Pi session replayed Pi branch outcomes" ;;
  esac
  [ -e "$home/state/.lease-task-dead" ] || fail "non-Pi session swept a Pi branch lease"
  [ ! -e "$home/state/.branch-outcomes-cursor" ] || fail "non-Pi session marked a Pi branch outcome read"
  pass "non-Pi session start neither sweeps nor replays Pi branch state"
}

test_session_start_seeds_the_outcome_display_tail_while_away() {
  local rec root home fakebin out store tail
  rec=$(new_world outcome-tail-seed)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  store="$home/state/branch-outcomes.jsonl"
  tail="$home/state/.branch-outcomes-tail.jsonl"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-a --verdict captain --summary 'decision still waiting' >/dev/null \
    || fail "could not store the captain outcome"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 1 || fail "could not mark the outcome read"
  rm -f "$tail"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'away for the afternoon' >/dev/null \
    || fail "could not record the away posture"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "away posture recorded" "the digest did not report the away posture"
  [ -f "$tail" ] || fail "session start did not seed the display tail copy of an existing outcome store while away"
  [ "$(cat "$tail")" = "$(cat "$store")" ] || fail "the seeded display tail is not the store's rows verbatim"
  [ "$(cat "$home/state/.branch-outcomes-cursor")" = 1 ] || fail "seeding the display tail moved the read cursor"
  [ ! -e "$home/state/.branch-outcomes-processed" ] || fail "seeding the display tail acknowledged the captain outcome"
  pass "session start seeds an existing outcome store's absent display tail copy while away, moving no marker"
}

# --- deferred network stage -------------------------------------------------

# install_slow_gh <fakebin> <seconds>: one external-network call the digest used
# to make directly. Making it pathologically slow is how a test stands in for an
# unreachable host without touching one: if any part of the blocking path still
# waits on the network, the digest cannot finish before this does.
install_slow_gh() {
  local fakebin=$1 seconds=$2 finished_marker=${3:-}
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ]; then
  sleep $seconds
  [ -z '$finished_marker' ] || : > '$finished_marker'
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/gh"
}

# The locked startup scan may need the same expensive current-state read that a
# busy validation makes slow. It belongs to the detached startup worker, so the
# digest must finish while that read is still outstanding; the answer then has to
# create the ordinary durable inactive-outcome wake rather than disappear
# off-path. The slow read is held open by this case rather than by a fixed sleep,
# so "the digest did not wait for it" is decided by what had happened when the
# digest returned and not by how fast the host was.
test_inactive_reconcile_never_blocks_the_digest() {
  local rec root home fakebin world worktree crew_state calls out waited=0
  local release_gate read_finished
  rec=$(new_world inactive-reconcile-deferred)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  world=${root%/root}
  worktree="$world/child-worktree"
  crew_state="$world/slow-crew-state.sh"
  calls="$world/no-mistakes-state.calls"
  ln -s "$ROOT/bin" "$root/bin"
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  fm_git_init_commit "$worktree"

  release_gate="$world/slow-state-read.release"
  read_finished="$world/slow-state-read.finished"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z'
  exit 0
fi
if [ "${1:-} ${2:-}" = 'axi status' ]; then
  if [ "${FM_BOOTSTRAP_NETWORK:-}" = only ]; then
    printf '%s\n' 'deferred' >> "${FM_FAKE_NM_CALLS:?}"
  else
    printf '%s\n' 'blocking' >> "${FM_FAKE_NM_CALLS:?}"
  fi
  # Stay outstanding until the case releases this read. A caller that waits for
  # it therefore waits indefinitely rather than for a fixed interval a loaded
  # host could out-run. The tick bound only stops a broken case hanging forever.
  ticks=0
  while [ ! -e "${FM_FAKE_NM_RELEASE:?}" ] && [ "$ticks" -lt 300 ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  : > "${FM_FAKE_NM_READ_FINISHED:?}"
  printf '%s\n' 'slow validation state answered'
fi
exit 0
SH
  cat > "$crew_state" <<'SH'
#!/usr/bin/env bash
set -u
no-mistakes axi status >/dev/null
printf '%s\n' 'state: done · source: run-step · passed'
SH
  chmod +x "$fakebin/no-mistakes" "$crew_state"

  fm_write_meta "$home/state/slow-child.meta" \
    'window=firstmate:fm-slow-child' "worktree=$worktree" 'project=firstmate' \
    'harness=pi' 'kind=scout' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=slow-child.1'
  printf '%s\n' 'working: validating' > "$home/state/slow-child.status"
  : > "$home/state/slow-child.turn-ended"
  touch -t 202001010000 "$home/state/slow-child.meta" \
    "$home/state/slow-child.status" "$home/state/slow-child.turn-ended"

  out=$(FM_BACKEND=tmux FM_FAKE_HARNESS_PID="$SESSION_START_TEST_HARNESS_PID" \
    FM_FAKE_NM_CALLS="$calls" FM_FAKE_NM_RELEASE="$release_gate" \
    FM_FAKE_NM_READ_FINISHED="$read_finished" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_RECONCILE_BUDGET_SECS=30 FM_INACTIVE_CREW_STATE_BIN="$crew_state" \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "SESSION START" "the digest did not complete"
  assert_absent "$read_finished" \
    "the digest waited for inactive reconciliation's still-unreleased state read"
  [ "$(grep -c '^blocking$' "$calls" 2>/dev/null || true)" -eq 0 ] \
    || fail "the digest called the slow state reader on its blocking path"
  : > "$release_gate"

  while ! grep -Fq $'\tcheck\tinactive-outcome:' "$home/state/.wake-queue" 2>/dev/null \
    && [ "$waited" -lt 150 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  assert_grep 'check	inactive-outcome:' "$home/state/.wake-queue" \
    "the deferred scan's terminal finding never reached the durable wake queue (calls=$(cat "$calls" 2>/dev/null), report=$(network_stage_report "$home" "$root" 2>/dev/null), queue=$(cat "$home/state/.wake-queue" 2>/dev/null))"
  [ "$(grep -c '^deferred$' "$calls" 2>/dev/null || true)" -eq 1 ] \
    || fail "the deferred scan did not make exactly one slow state read"
  pass "session start: inactive reconciliation runs after the digest and retains its durable wake"
}

# The headline guarantee: an unreachable host delays a reported CHECK, never the
# startup. The fake host hangs for 12s; the digest must be done long before that,
# must say so rather than implying the checks passed, and the sweeps must still
# run and land afterwards.
test_unreachable_network_never_blocks_the_digest() {
  local rec root home fakebin mate log spawned network_finished out started elapsed
  rec=$(prepare_session_start_secondmate secondmate-slow-network)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF
  network_finished="${root%/root}/network-finished"
  install_slow_gh "$fakebin" 12 "$network_finished"

  started=$(date +%s)
  out=$(run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" missing)
  elapsed=$(( $(date +%s) - started ))

  [ ! -e "$network_finished" ] \
    || fail "the digest waited for the 12s unreachable-host probe instead of returning from local state (${elapsed}s)"
  assert_contains "$out" "SESSION START" "the digest did not complete"
  assert_contains "$out" "IN PROGRESS - the deferred network checks have not finished yet." \
    "the digest did not disclose that its network checks were still running"
  assert_contains "$out" "NOT yet confirmed: GitHub authentication, dead-secondmate relaunch" \
    "the digest did not name the checks it has not confirmed"
  assert_not_contains "$out" "NEEDS_GH_AUTH" \
    "the digest reported a GitHub-auth verdict it could not yet have"

  # ... and the work itself still happens, off the blocking path.
  wait_for_network_stage "$home" "$root" 60 \
    || fail "the deferred stage never finished: $(network_stage_report "$home" "$root")"
  assert_contains "$(network_stage_report "$home" "$root")" "NEEDS_GH_AUTH" \
    "the deferred stage lost the GitHub-auth verdict it was deferring"
  assert_contains "$(cat "$log")" "new-window" \
    "the deferred stage lost the dead-secondmate relaunch"
  pass "session start: an unreachable host delays a reported check, not the digest"
}

# A result the digest could not print must still reach the agent by itself. The
# opposite half of the handshake - a printed result never ALSO queuing a wake -
# is asserted deterministically in tests/fm-startup-network.test.sh, where the
# claim can be set up directly instead of raced against digest composition.
test_deferred_result_reaches_the_agent_when_the_digest_cannot_print_it() {
  local rec root home fakebin mate log spawned queue
  rec=$(prepare_session_start_secondmate secondmate-wake-once)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF
  install_slow_gh "$fakebin" 8
  queue="$home/state/.wake-queue"

  run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" missing >/dev/null
  wait_for_network_stage "$home" "$root" 60 || fail "the deferred stage never finished"
  wait_for_network_wake "$home" 60 || fail "the deferred stage never settled wake delivery"
  assert_grep 'check	startup-network' "$queue" \
    "a result the digest could not print never reached the agent: $(cat "$queue" 2>/dev/null)"
  pass "session start: a deferred result the digest outran still reaches the agent as a wake"
}

# A read-only session has no lock, so it neither owns the mutating sweeps nor has
# any action a GitHub-auth verdict would gate. It must say that plainly instead of
# quietly dropping the checks.
test_read_only_session_declares_skipped_network_checks() {
  local rec root home fakebin out
  rec=$(new_world network-read-only)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"-p 999999"*) printf 'claude\n'; exit 0 ;;
  *"comm="*|*"args="*) printf 'bash\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "READ-ONLY SESSION" "the read-only fixture did not actually refuse the lock"
  assert_contains "$out" "skipped (read-only session) - GitHub authentication" \
    "a read-only session did not declare its skipped network checks"
  assert_absent "$home/state/.startup-network.status" \
    "a read-only session started the deferred stage it has no authority for"
  pass "session start: a read-only session declares its skipped network checks rather than dropping them"
}

# The compatibility verdict costs three tasks-axi subprocesses and one session
# start needs it twice. The digest must pay for it once.
test_tasks_axi_compatibility_is_probed_once() {
  local rec root home fakebin log probes
  rec=$(new_world tasks-axi-once)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  log="$home/tasks-axi.log"
  printf '# Backlog\n\n## In flight\n\n## Queued\n' > "$home/data/backlog.md"

  FM_FAKE_TASKS_AXI_LOG="$log" run_session_start "$home" "$root" "$fakebin:$BASE_PATH" >/dev/null

  probes=$(grep -c -- '--version' "$log" || true)
  [ "$probes" -eq 1 ] \
    || fail "tasks-axi was version-probed $probes times in one session start: $(cat "$log")"
  probes=$(grep -c -- 'update --help' "$log" || true)
  [ "$probes" -eq 1 ] \
    || fail "tasks-axi update --help ran $probes times in one session start: $(cat "$log")"
  assert_grep 'ready --file' "$log" "the backlog listing never ran, so the verdict was not actually reused"
  pass "session start: the tasks-axi compatibility verdict is computed once and reused"
}

# --- fleet-state digest: compact backlog rendering --------------------------

# A backlog whose Done section, held row, blocked row, and plain queued rows can
# each be told apart in the rendered digest. DONE-ROW-LINE and the *-BODY-LINE
# markers exist so a leak is unmistakable.
write_long_body_backlog() {
  local path=$1 i=1
  cat > "$path" <<'EOF'
# Backlog

## In flight
- [ ] compact-startup - Compact startup digest (repo: firstmate) (kind: ship) (since 2026-07-15) (hold: captain choice pending) (hold-kind: captain)
  OVERSIZED-BODY-LINE current startup leaks task note bodies into the session digest.
  Another long body line that should not be printed after the fix.

## Queued
- [ ] blocked-followup - Follow compact startup blocked-by: compact-startup - waits for implementation (repo: firstmate) (kind: scout) (since 2026-07-15)
  QUEUED-BODY-LINE this is another long multiline note.
- [ ] held-queued - Held queued work (repo: firstmate) (kind: ship) (hold: captain choice pending) (hold-kind: captain)
EOF
  while [ "$i" -le 25 ]; do
    printf -- '- [ ] plain-%s - Plain queued item %s (repo: firstmate) (kind: ship)\n' "$i" "$i" >> "$path"
    i=$((i + 1))
  done
  cat >> "$path" <<'EOF'

## Done
- [x] landed-earlier - DONE-ROW-LINE already landed and torn down (repo: firstmate) (kind: ship)
EOF
}

test_backlog_compact_tasks_axi_omits_bodies_and_keeps_metadata() {
  local rec root home fakebin out log
  rec=$(new_world backlog-compact-tasks-axi)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"
  mkdir -p "$home/projects/firstmate"
  printf 'window=fm-sess:compact\nworktree=%s\nproject=firstmate\nkind=ship\n' "$home/projects/firstmate" \
    > "$home/state/compact-startup.meta"
  log="$home/tasks-axi.log"

  out=$(FM_FAKE_TASKS_AXI_LOG="$log" FM_FAKE_TASKS_AXI_READY=3 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (tasks-axi; done rows omitted; every in-flight, held, and blocked row shown once with hold fields capped to 250 chars; ready queued bounded to 20; task bodies omitted)" \
    "compatible tasks-axi backend did not render the compact backlog listing"
  assert_contains "$out" "tasks[1]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:" \
    "tasks-axi compact listing omitted the expected structured field header"
  assert_contains "$out" "compact-startup,in_flight,ship,firstmate,Compact startup digest,none,captain,captain choice pending" \
    "tasks-axi compact listing omitted in-flight identity, state, or hold metadata"
  assert_contains "$out" "held-queued,queued,ship,firstmate,Held queued work,none,captain,captain choice pending" \
    "tasks-axi compact listing omitted a held row or its hold metadata"
  assert_contains "$out" 'blocked-followup,queued,scout,firstmate,Follow compact startup,compact-startup,"-","-"' \
    "tasks-axi compact listing omitted blocked-by metadata"
  assert_contains "$out" "ready-3,queued,ship,firstmate,Ready item 3" \
    "tasks-axi compact listing omitted a dispatchable queued row inside the bound"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "tasks-axi compact digest leaked an in-flight task body"
  assert_not_contains "$out" "QUEUED-BODY-LINE" "tasks-axi compact digest leaked a queued task body"
  assert_not_contains "$out" "DONE-ROW-LINE" "tasks-axi compact digest listed a done row at startup"
  assert_contains "$out" "--- compact-startup ---" "in-flight meta identity disappeared from startup recovery digest"
  assert_contains "$out" "worktree=$home/projects/firstmate" "in-flight recovery worktree identity disappeared from startup digest"
  assert_contains "$out" "Full task bodies remain available on demand: bin/fm-tasks-axi.sh show <id> --full" \
    "compact digest omitted the full-body lookup pointer"
  assert_contains "$out" "ready_public_followups: 0 delivery-ready obligations" \
    "the composed listing dropped a real signal from the dispatchable set"
  # One section pointer, not one repeated help block per composed group.
  assert_not_contains "$out" "help[1]:" \
    "the composed listing repeated tasks-axi's per-group help block"

  # The fake refuses a body field, an unfiltered listing, and a done listing, so
  # a clean render already proves those were never asked for; pin the group
  # filters the listing is built from.
  assert_grep "--state in_flight --fields blocked_by,hold_kind,hold_reason" "$log" \
    "session start did not ask tasks-axi for the in-flight group"
  assert_grep "--state held --fields blocked_by,hold_kind,hold_reason" "$log" \
    "session start did not ask tasks-axi for the held group"
  assert_grep "--state queued --blocked --fields blocked_by,hold_kind,hold_reason" "$log" \
    "session start did not ask tasks-axi for the blocked queued group"
  assert_grep "ready --file $home/data/backlog.md" "$log" \
    "session start did not ask tasks-axi for the dispatchable queued set"

  pass "compatible tasks-axi backlog rendering drops done rows and keeps every in-flight, held, and blocked row"
}

# An in-flight-and-held task must appear once, with its hold fields, not once
# per group; an oversized hold_reason must be capped with a pointer to the
# full text rather than passed through verbatim.
test_backlog_compact_dedupes_held_and_caps_hold_reason() {
  local rec root home fakebin out
  rec=$(new_world backlog-compact-dedupe-cap)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_tasks_axi_dupe_and_long_reason "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "both-states,in_flight,ship,firstmate,Shared row,none,captain,captain choice pending" \
    "the shared in-flight-and-held row did not render under in flight"
  assert_contains "$out" "already shown with full hold fields under in flight" \
    "the held group did not disclose that the shared row was deduplicated"

  local in_flight_count held_count
  in_flight_count=$(printf '%s\n' "$out" | grep -c '^  both-states,in_flight,ship,firstmate,Shared row')
  [ "$in_flight_count" -eq 1 ] || fail "expected the shared row exactly once, found $in_flight_count: $out"

  held_count=$(printf '%s\n' "$out" | grep -c 'held-only,queued,ship,firstmate,Held only')
  [ "$held_count" -eq 1 ] || fail "expected the held-only row exactly once, found $held_count"

  assert_not_contains "$out" "$(printf 'x%.0s' $(seq 1 251))" \
    "an oversized hold_reason was not capped"
  assert_contains "$out" "tasks-axi show held-only --full for the rest" \
    "a capped hold_reason did not point at the full-text lookup"

  assert_contains "$out" "tasks[2]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:" \
    "the held group header count was not rewritten to the rows actually printed"
  assert_not_contains "$out" "tasks[3]{" \
    "the held group header still advertises the pre-dedupe row count"

  printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
    || fail "capping a hold_reason split a multi-byte character: $out"

  pass "the compact backlog listing lists an in-flight-and-held task once and caps an oversized hold_reason"
}

# The bound may only ever cut the dispatchable-now listing, and whatever it cuts
# must be disclosed with an exact count and the command that shows the rest.
test_backlog_queued_bound_discloses_its_remainder() {
  local rec root home fakebin out
  rec=$(new_world backlog-queued-bound)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"

  out=$(FM_FAKE_TASKS_AXI_READY=7 FM_SESSION_START_QUEUED_LIMIT=3 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "ready-3,queued,ship,firstmate,Ready item 3" \
    "the queued bound dropped a row inside its own limit"
  assert_not_contains "$out" "ready-4,queued" "the queued bound did not actually bound the ready listing"
  assert_contains "$out" "(shown 3 of 7 ready queued item(s))" \
    "the bounded queued listing did not report what it showed"
  assert_contains "$out" "(4 more queued - bin/fm-tasks-axi.sh ready)" \
    "the bounded queued listing did not disclose an exact remainder and how to see it"

  # The bound is for dispatchable work only: held and blocked rows stay whole.
  assert_contains "$out" "held-queued,queued,ship,firstmate,Held queued work,none,captain,captain choice pending" \
    "the queued bound swallowed a held row"
  assert_contains "$out" 'blocked-followup,queued,scout,firstmate,Follow compact startup,compact-startup,"-","-"' \
    "the queued bound swallowed a blocked row"
  assert_contains "$out" "compact-startup,in_flight,ship,firstmate,Compact startup digest,none,captain,captain choice pending" \
    "the queued bound swallowed an in-flight row"

  pass "the startup backlog bound cuts only dispatchable queued rows and discloses the remainder exactly"
}

test_backlog_compact_manual_backend_skips_indented_bodies() {
  local rec root home fakebin out
  rec=$(new_world backlog-compact-manual)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\n' manual > "$home/config/backlog-backend"
  write_long_body_backlog "$home/data/backlog.md"

  out=$(FM_SESSION_START_QUEUED_LIMIT=4 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (manual backend; done rows omitted; every in-flight, held, and blocked title line kept; other queued bounded to 4; indented task bodies omitted)" \
    "manual backend did not use compact title-line rendering"
  assert_contains "$out" "## In flight" "manual compact rendering omitted the in-flight section heading"
  assert_contains "$out" "- [ ] compact-startup - Compact startup digest" \
    "manual compact rendering omitted the in-flight title line"
  assert_contains "$out" "(hold: captain choice pending) (hold-kind: captain)" \
    "manual compact rendering omitted hold metadata"
  assert_contains "$out" "blocked-by: compact-startup - waits for implementation" \
    "manual compact rendering omitted blocker metadata"
  assert_contains "$out" "- [ ] held-queued - Held queued work" \
    "manual compact rendering dropped a held queued title line"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "manual compact digest leaked an in-flight task body"
  assert_not_contains "$out" "QUEUED-BODY-LINE" "manual compact digest leaked a queued task body"
  assert_not_contains "$out" "DONE-ROW-LINE" "manual compact digest listed a done row at startup"
  assert_not_contains "$out" "## Done" "manual compact digest printed the done heading it never fills"
  assert_contains "$out" "- [ ] plain-4 - Plain queued item 4" \
    "manual compact rendering dropped a queued title line inside its bound"
  assert_not_contains "$out" "- [ ] plain-5 - Plain queued item 5" \
    "manual compact rendering did not bound its plain queued listing"
  assert_contains "$out" "(shown 1 in-flight, 2 held or blocked queued, 4 of 25 other queued title line(s); 1 done row(s) omitted)" \
    "manual compact rendering did not report its bound accounting"
  assert_contains "$out" "(21 more queued - raise FM_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)" \
    "manual compact rendering did not disclose an exact queued remainder"
  assert_contains "$out" "or data/backlog.md" "manual compact digest omitted the data/backlog.md full-body pointer"

  pass "manual backlog rendering drops done rows, keeps every held or blocked title line, and bounds the rest"
}
