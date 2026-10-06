#!/usr/bin/env bash
# Content-preserving upstream test block, sourced by fm-wake-queue.test.sh.

test_branch_actor_scoped_ack_never_swallows_a_main_owned_row() {
  local dir state out err sequence generation count
  dir=$(make_case actor-scope)
  state="$dir/state"

  append_wake "$state" check "some-poll.check.sh" "check: some-poll.check.sh: merged" \
    || fail "main-only append failed"
  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  append_wake "$state" stale "fm-window" "stale: fm-window" || fail "stale append failed"

  # The extension's own job (fm-branch-dispatch.ts) is granting exactly the
  # two task-local rows; this test drives the bash consume contract those
  # sequence numbers gate, independent of the Pi SDK.
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" actor-scope || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish actor-scope 2 3 || fail "branch grant publication failed"

  out="$dir/branch-drain.out"
  err="$dir/branch-drain.err"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$out" 2> "$err" \
    || fail "branch-scoped drain failed: $(cat "$err")"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$out" || fail "branch drain omitted its eligible signal row"
  grep -Fq "$(printf '\tstale\tfm-window\t')" "$out" || fail "branch drain omitted its eligible stale row"
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$out" && fail "branch drain presented the main-owned row"

  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "branch drain omitted its acknowledgement boundary"
  [ "$sequence" -eq 3 ] || fail "branch ack cutoff must be the max ELIGIBLE seq (3), got $sequence"

  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "branch-scoped ack failed"

  # The core no-swallow property: the main-only row - seq 1, BELOW the
  # branch's own ack cutoff of 3 - must still be there.
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$state/.wake-queue" \
    || fail "branch's scoped ack swallowed a main-owned row below its own cutoff"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$state/.wake-queue" \
    && fail "branch's own eligible signal row was not consumed"
  grep -Fq "$(printf '\tstale\tfm-window\t')" "$state/.wake-queue" \
    && fail "branch's own eligible stale row was not consumed"

  # Main's own later, ordinary (unscoped) drain sees exactly what remains.
  out="$dir/main-drain.out"
  err="$dir/main-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "main drain failed: $(cat "$err")"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 1 ] || fail "main's later drain should see exactly the one remaining main-owned row: $(cat "$out")"
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$out" || fail "main's later drain lost the main-owned row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "main's drain omitted its acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "main's ack failed"
  [ ! -s "$state/.wake-queue" ] || fail "the main-owned row survived main's own ack"

  pass "a branch-actor scoped ack never swallows an unacked main-owned row, and main's later drain sees exactly what remains"
}

test_main_drain_excludes_rows_already_granted_to_branch() {
  local dir state out err sequence generation
  dir=$(make_case main-excludes-branch-grant)
  state="$dir/state"

  append_wake "$state" check "some-poll.check.sh" "check: some-poll.check.sh: merged" \
    || fail "main-only append failed"
  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" main-excludes || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish main-excludes 2 || fail "branch grant publication failed"

  out="$dir/main-drain.out"
  err="$dir/main-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "main drain failed: $(cat "$err")"
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$out" || fail "main drain omitted its main-owned row"
  ! grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$out" || fail "main drain presented a branch-granted row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ "$sequence" = 1 ] && [ -n "$generation" ] || fail "main acknowledgement did not bind only its presented row"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "main acknowledgement failed"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$state/.wake-queue" \
    || fail "main acknowledgement consumed the branch-granted row"

  out="$dir/branch-drain.out"
  err="$dir/branch-drain.err"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$out" 2> "$err" \
    || fail "branch drain failed: $(cat "$err")"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$out" || fail "branch lost its granted row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "branch acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "branch acknowledgement left its handled row queued"
  [ ! -e "$state/.branch-eligible-rows" ] || fail "branch acknowledgement retained its completed grant"

  pass "main drain and acknowledgement exclude an active branch grant"
}

# The away posture lets a branch grant name a check-kind row, so the branch
# ack must close the same publish-before-receipt crash window the main ack
# does: consuming a secondmate-wake-loop row commits its stall receipt under
# exactly the granted sequences, keeping a later stall tick from re-alerting a
# consumed notification.
test_branch_ack_commits_secondmate_stall_receipts() {
  local dir state epoch sequence generation receipt
  dir=$(make_case secondmate-branch-stall)
  state="$dir/state"
  epoch=$(( $(date +%s) - 10 ))
  append_wake "$state" check "secondmate-wake-loop-mate-$epoch-7" \
    "check: secondmate wake-loop stalled: mate=mate row=7 idle=2s" \
    || fail "could not seed the stall publication"
  append_wake "$state" check "secondmate-wake-loop-mate-$epoch-9" \
    "check: secondmate wake-loop stalled: mate=mate row=9 idle=3s" \
    || fail "could not seed the ungranted stall publication"

  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" branch-stall \
    || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish branch-stall 1 \
    || fail "branch grant publication failed"

  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/branch.out" 2> "$dir/branch.err" \
    || fail "branch drain failed: $(cat "$dir/branch.err")"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/branch.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/branch.err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "branch drain omitted its acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" \
    --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "branch acknowledgement failed"

  receipt="$state/.secondmate-wake-stall-receipts/mate/$epoch-7"
  [ "$(cat "$receipt" 2>/dev/null || true)" = "$epoch-7" ] \
    || fail "branch acknowledgement did not commit the consumed stall row's receipt"
  receipt="$state/.secondmate-wake-stall-receipts/mate/$epoch-9"
  [ ! -e "$receipt" ] \
    || fail "branch acknowledgement committed a stall receipt for a row outside its grant"
  pass "a branch-actor acknowledgement commits secondmate stall receipts for exactly its granted rows"
}

# The pending-warning condition and what a drain can actually present must name
# the same rows. A row reserved by a live branch grant is invisible to a main
# drain by design, so counting it as "queued for main" told main to run a drain
# that could only print nothing - no row, no acknowledgement command - on every
# guarded command, for as long as the branch held the grant.
test_main_is_never_told_to_drain_rows_only_the_branch_owns() {
  local dir state out err sequence generation
  dir=$(make_case main-not-told-to-drain-branch-rows)
  state="$dir/state"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"

  append_wake "$state" stale "fleet:w2:p3" "stale: fleet:w2:p3 (paused, awaiting external)" \
    || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" held-by-branch || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish held-by-branch 1 || fail "branch grant publication failed"

  out="$dir/main-drain.out"
  err="$dir/main-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "main drain failed: $(cat "$err")"
  ! grep -Fq "$(printf '\tstale\tfleet:w2:p3\t')" "$out" || fail "main drain presented a branch-granted row"
  grep -Fq 'WAKE ROWS HELD BY SUPERVISION BRANCH' "$out" \
    || fail "main drain went silent instead of naming who holds the queued rows"
  ! grep -Fq 'WAKE_ACK_REQUIRED' "$err" || fail "main drain offered an acknowledgement for a row it never presented"
  ! grep -Fq 'queued wakes pending' "$err" \
    || fail "main was told to drain rows only the branch can present"
  FM_STATE_OVERRIDE="$state" "$GUARD" 2> "$dir/guard-held.err" || fail "guard failed while the branch held the rows"
  ! grep -Fq 'queued wakes pending' "$dir/guard-held.err" \
    || fail "guard counted branch-held rows as pending for main"
  grep -Fq 'wake rows held by the live supervision branch' "$dir/guard-held.err" \
    || fail "guard went silent about a non-empty queue instead of naming the branch as its holder"
  grep -Fq 'do not drain them from here' "$dir/guard-held.err" \
    || fail "the held advisory did not say the rows must not be drained from here"
  grep -Fq "$(printf '\tstale\tfleet:w2:p3\t')" "$state/.wake-queue" \
    || fail "the branch-held row must stay durable for its own owner"

  # Disconfirming half: the same row, same kind, same stopped endpoint, with the
  # grant released. Nothing about the row makes it unpresentable - only the
  # live grant did - so main now presents it with an executable acknowledgement.
  FM_STATE_OVERRIDE="$state" "$GRANT" release held-by-branch || fail "branch grant release failed"
  out="$dir/main-drain-after.out"
  err="$dir/main-drain-after.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "main drain failed after release: $(cat "$err")"
  grep -Fq "$(printf '\tstale\tfleet:w2:p3\t')" "$out" || fail "main drain omitted the released row"
  ! grep -Fq 'WAKE ROWS HELD BY SUPERVISION BRANCH' "$out" \
    || fail "main drain reported a hold that no longer exists"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "the released row was presented without an acknowledgement command"
  grep -Fq 'queued wakes pending' "$err" || fail "guard stopped warning about a row main can actually drain"
  ! grep -Fq 'wake rows held by the live supervision branch' "$err" \
    || fail "guard kept advising about a hold that was already released"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "acknowledgement of the released row failed"
  [ ! -s "$state/.wake-queue" ] || fail "the acknowledged row stayed queued"

  pass "a branch-held row raises no queued-wake warning for main, and the same row is presented and acknowledged once the grant clears"
}

# The pending-warning condition must also survive a queue nobody could read: a
# queue that exists but cannot be counted is not evidence that it was drained.
# The per-actor count runs awk over the queue, and awk implementations differ on
# whether a failed input open aborts before the END rule; one that reaches END
# reports a 0 count for a queue that was never proved empty.
test_uncountable_queue_still_raises_the_pending_alarm() {
  local dir state awkbin real_awk
  dir=$(make_case uncountable-queue)
  state="$dir/state"
  awkbin="$dir/awkbin"
  mkdir -p "$awkbin"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"

  # An awk that still runs its END rule after failing to open its input: it
  # prints a 0 count and exits non-zero. Every other invocation is the real awk.
  real_awk=$(command -v awk) || fail "no awk on PATH"
  cat > "$awkbin/awk" <<SH
#!/usr/bin/env bash
set -u
for _arg in "\$@"; do _last=\$_arg; done
if [ -n "\${_last:-}" ] && [ -e "\$_last" ] && [ ! -r "\$_last" ]; then
  printf '0\\n'
  exit 2
fi
exec "$real_awk" "\$@"
SH
  chmod +x "$awkbin/awk"

  append_wake "$state" stale "fleet:w2:p3" "stale: fleet:w2:p3 (paused, awaiting external)" \
    || fail "stale append failed"
  chmod 000 "$state/.wake-queue" || fail "could not make the queue unreadable"
  PATH="$awkbin:$PATH" FM_STATE_OVERRIDE="$state" "$GUARD" 2> "$dir/unreadable.err" \
    || fail "guard failed on an unreadable queue"
  grep -Fq 'queued wakes pending' "$dir/unreadable.err" \
    || fail "a queue that could not be counted silenced the queued-wake alarm"
  chmod 600 "$state/.wake-queue" || fail "could not restore the queue"

  # Disconfirming half: the same fake awk over a queue that is readable and
  # provably empty stays silent, so the warning above came from the failed count
  # and not from the fake awk itself.
  : > "$state/.wake-queue"
  PATH="$awkbin:$PATH" FM_STATE_OVERRIDE="$state" "$GUARD" 2> "$dir/empty.err" \
    || fail "guard failed on an empty queue"
  ! grep -Fq 'queued wakes pending' "$dir/empty.err" \
    || fail "a provably empty queue raised the queued-wake alarm"

  pass "a queue that cannot be counted keeps the queued-wake alarm up"
}

# A row that lost its structure can never be claimed, presented, or named by an
# --ack-through cutoff, while it still counts as queued: without retirement it
# wedges the queue permanently and keeps waking supervision.
test_unconsumable_rows_are_retired_instead_of_wedging_the_queue() {
  local dir state out err sequence generation
  dir=$(make_case unconsumable-row-retirement)
  state="$dir/state"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"

  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  printf '1788792074\t574\tstale\tfleet:w2:p3\n' >> "$state/.wake-queue"
  printf '1788792075\tnot-a-sequence\tstale\tfleet:w2:p4\tstale: fleet:w2:p4\n' >> "$state/.wake-queue"

  # A branch actor never repairs the queue: it may only touch its own grant.
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" retire-scope || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish retire-scope 1 || fail "branch grant publication failed"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/branch.out" 2> "$dir/branch.err" \
    || fail "branch drain failed: $(cat "$dir/branch.err")"
  ! grep -Fq 'retired' "$dir/branch.err" || fail "a branch drain retired rows outside its grant"
  [ "$(awk 'END { print NR }' "$state/.wake-queue")" -eq 3 ] \
    || fail "a branch drain changed rows it was never granted"
  FM_STATE_OVERRIDE="$state" "$GRANT" release retire-scope || fail "branch grant release failed"

  FM_STATE_OVERRIDE="$state" "$GUARD" 2> "$dir/guard-before.err" || fail "guard failed with unusable rows queued"
  grep -Fq 'queued wakes pending' "$dir/guard-before.err" \
    || fail "guard stayed silent about rows main still has to clear"
  ! grep -Fq 'wake rows held by the live supervision branch' "$dir/guard-before.err" \
    || fail "guard advised a branch hold for rows no grant covers"

  out="$dir/main.out"
  err="$dir/main.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "main drain failed: $(cat "$err")"
  grep -Fq 'retired 2 unusable queue row(s)' "$err" || fail "main drain did not report the rows it retired"
  grep -Fq "$(printf '1788792074\t574\tstale\tfleet:w2:p3')" "$err" \
    || fail "the retired row's content was discarded instead of reported"
  grep -Fq "$(printf '1788792075\tnot-a-sequence\tstale\tfleet:w2:p4\tstale: fleet:w2:p4')" "$err" \
    || fail "the second retired row's content was discarded instead of reported"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$out" || fail "retirement dropped a usable row"
  [ "$(awk 'END { print NR }' "$state/.wake-queue")" -eq 1 ] || fail "unusable rows survived the drain"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "the usable row was presented without an acknowledgement command"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "the queue stayed wedged after acknowledgement"
  FM_STATE_OVERRIDE="$state" "$GUARD" 2> "$dir/guard-after.err" || fail "guard failed after the queue drained"
  ! grep -Fq 'queued wakes pending' "$dir/guard-after.err" || fail "guard kept warning about an empty queue"

  pass "structurally unusable rows are retired by main alone, leaving every remaining row presentable and acknowledgeable"
}

test_branch_grant_refuses_rows_already_claimed_by_main() {
  local dir state rc
  dir=$(make_case branch-refuses-main-claim)
  state="$dir/state"

  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" \
    || fail "main presentation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" branch-refuses || fail "branch owner activation failed"
  rc=0
  FM_STATE_OVERRIDE="$state" "$GRANT" publish branch-refuses 1 || rc=$?
  [ "$rc" -eq 3 ] || fail "branch grant did not report the existing main ownership: rc=$rc"
  [ ! -e "$state/.branch-eligible-rows" ] || fail "refused branch grant published an ownership snapshot"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$dir/main.out" \
    || fail "the main owner did not present its claimed row"

  pass "branch grant cannot take a row already claimed by main"
}

# A wake that lands between main's drain and its acknowledgement was never
# presented to main and sits above the printed cutoff, so the acknowledgement
# must leave it unowned: an away-session grant can still take it, and main's
# next drain still presents it. Claiming it for main instead handed every later
# away wake back to main until main drained again.
test_main_ack_leaves_a_row_that_arrived_after_its_drain_unclaimed() {
  local dir state sequence generation rc
  dir=$(make_case main-ack-leaves-late-row)
  state="$dir/state"

  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "first signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" \
    || fail "main presentation failed"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/main.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/main.err")
  [ "$sequence" = 1 ] || fail "main was not asked to acknowledge exactly its presented row: $(cat "$dir/main.err")"

  append_wake "$state" signal "task-b.status" "signal: task-b" || fail "late signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    > "$dir/ack.out" 2> "$dir/ack.err" || fail "main acknowledgement failed: $(cat "$dir/ack.err")"
  grep -Fq "$(printf '\tsignal\ttask-b.status\t')" "$state/.wake-queue" \
    || fail "main's acknowledgement consumed a row it was never shown"

  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" late-row || fail "branch owner activation failed"
  rc=0
  FM_STATE_OVERRIDE="$state" "$GRANT" publish late-row 2 || rc=$?
  [ "$rc" -eq 0 ] || fail "an away-session grant could not take a row main never saw: rc=$rc"
  FM_STATE_OVERRIDE="$state" "$GRANT" release late-row || fail "branch grant release failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" deactivate "$$" late-row || fail "branch owner deactivation failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main2.out" 2> "$dir/main2.err" \
    || fail "main's next drain failed"
  grep -Fq "$(printf '\tsignal\ttask-b.status\t')" "$dir/main2.out" \
    || fail "main's next drain did not present the late row: $(cat "$dir/main2.out" "$dir/main2.err")"

  pass "main's acknowledgement leaves a row that arrived after its drain for whichever actor takes it next"
}

test_actor_filter_precedes_same_key_deduplication() {
  local dir state main_sequence main_generation branch_sequence branch_generation
  dir=$(make_case actor-dedup-order)
  state="$dir/state"

  append_wake "$state" signal "task-a.status" "signal: branch version" || fail "branch row append failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" actor-dedup || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish actor-dedup 1 || fail "branch grant publication failed"
  append_wake "$state" signal "task-a.status" "signal: main version" || fail "main row append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" || fail "main drain failed"
  [ "$(awk -F '\t' '$3 == "signal" { print $2 }' "$dir/main.out")" = 2 ] \
    || fail "main did not present its same-key claimed row"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/branch.out" 2> "$dir/branch.err" \
    || fail "branch drain failed"
  [ "$(awk -F '\t' '$3 == "signal" { print $2 }' "$dir/branch.out")" = 1 ] \
    || fail "global deduplication hid the branch's older same-key row"

  main_sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/main.err")
  main_generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/main.err")
  branch_sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/branch.err")
  branch_generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/branch.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$main_sequence" --recovery-generation "$main_generation" \
    || fail "main same-key acknowledgement failed"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$branch_sequence" --recovery-generation "$branch_generation" \
    || fail "branch same-key acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "same-key actor rows remained stranded"

  pass "actor ownership filtering precedes same-key deduplication"
}

test_main_reclaims_a_grant_whose_branch_owner_exited() {
  local dir state owner sequence generation
  dir=$(make_case stale-branch-owner)
  state="$dir/state"

  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  sleep 30 &
  owner=$!
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$owner" stale-owner || {
    kill "$owner" 2>/dev/null || true
    fail "branch owner activation failed"
  }
  FM_STATE_OVERRIDE="$state" "$GRANT" publish stale-owner 1 || {
    kill "$owner" 2>/dev/null || true
    fail "branch grant publication failed"
  }
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" || fail "main reclaim drain failed"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$dir/main.out" \
    || fail "main did not reclaim the dead branch owner's row"
  [ ! -e "$state/.branch-eligible-rows" ] && [ ! -e "$state/.branch-eligible-owner" ] \
    || fail "dead branch ownership evidence survived reclaim"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/main.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/main.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "reclaimed row acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "reclaimed branch row remained queued"

  pass "main reclaims rows granted to an exited branch owner"
}

# A branch-actor drain or ack without a snapshot is a wiring bug, never
# "nothing eligible": it must refuse loudly rather than silently draining or
# acking nothing.
test_branch_actor_without_eligible_snapshot_refuses() {
  local dir state
  dir=$(make_case actor-no-snapshot)
  state="$dir/state"
  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "append failed"
  if FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" >/dev/null 2>"$dir/err"; then
    fail "a branch-actor drain with no eligible-row snapshot must refuse, not silently drain"
  fi
  grep -q "no branch-eligible row snapshot" "$dir/err" || fail "the refusal did not name the missing snapshot: $(cat "$dir/err")"
  [ -s "$state/.wake-queue" ] || fail "the refused drain must leave the queue untouched"
  pass "a branch-actor drain with no eligible-row snapshot refuses loudly instead of draining nothing"
}

test_wake_publish_requires_atomic_recovery_evidence() {
  local dir state fakebin real_mv rc out
  dir=$(make_case wake-publish-recovery-evidence)
  state="$dir/state"
  fakebin="$dir/fakebin"
  real_mv=$(command -v mv) || fail "could not locate mv for recovery publication fixture"
  printf 'pending:handling:existing\n' > "$state/.watcher-down"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "${FM_TEST_PUBLISH_MARKER:-}" ]; then
  exit 1
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"

  set +e
  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" FM_TEST_PUBLISH_MARKER="$state/.watcher-down" \
    append_wake "$state" signal task.status "signal: publish failure"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "recovery publication failure allowed wake append to succeed"
  [ "$(cat "$state/.watcher-down")" = 'pending:handling:existing' ] \
    || fail "failed atomic publication erased existing recovery evidence"
  [ ! -s "$state/.wake-queue" ] \
    || fail "wake became durable before its recovery evidence"

  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" \
    append_wake "$state" signal task.status "signal: recovered retry" \
    || fail "wake retry did not publish durable recovery evidence"
  out="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake retry did not drain"
  grep -F "signal: recovered retry" "$out" >/dev/null \
    || fail "retried wake was not recovered by the durable drain"
  pass "wake append publishes atomic recovery evidence before durable rows"
}

# Recovery mint and wake-delivery logging must not use sibling $() on one
# command (bash 5.2 CHLD-trap parse landmine). Mint failure semantics stay as
# before: a pid/date miss still yields a grammar-valid token and a durable row.
test_recovery_mint_and_delivery_log_avoid_sibling_subst() {
  local dir state marker generation line
  dir=$(make_case recovery-mint-sibling-subst)
  state="$dir/state"

  append_wake "$state" check task 'check: recovery mint' \
    || fail "recovery mint wake append failed"
  marker=$(cat "$state/.watcher-down")
  case "$marker" in
    pending:handling:*|pending:downtime:*) ;;
    *) fail "recovery mint did not write a pending marker: $marker" ;;
  esac
  generation=${marker##*:}
  case "$generation" in
    ''|*[!A-Za-z0-9._-]*) fail "recovery mint produced an empty or invalid generation: [$generation]" ;;
  esac
  case "$generation" in
    [0-9]*.[0-9]*.*) ;;
    *) fail "recovery mint generation lost pid.epoch.suffix shape: $generation" ;;
  esac

  # Delivery log: sequential cleaners, then one printf (no sibling $() args).
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1/bin/fm-push-transition-lib.sh"
    FM_WATCH_DELIVERY_PID=4242
    FM_WATCH_DELIVERY_IDENTITY="pane'$'\t''id"
    watch_delivery_publish "signal: delivery log"
  ' _ "$ROOT" || fail "watch_delivery_publish failed"
  [ -s "$state/.watch-deliveries.log" ] \
    || fail "watch_delivery_publish wrote no delivery log"
  line=$(tail -n 1 "$state/.watch-deliveries.log")
  case "$line" in
    4242*$'\t'*signal:\ delivery\ log) ;;
    *) fail "delivery log line lost pid/identity/reason shape: $line" ;;
  esac

  # Historical bash 5.2 repro used CHLD + sibling $(); when bash >= 5 is the
  # runner, confirm the public mint still yields a nonempty generation with no
  # trap parse error. Bash 5.2 is not installed on this host — skip otherwise.
  if [ "${BASH_VERSINFO[0]}" -ge 5 ]; then
    rm -f -- "$state/.watcher-down"
    FM_STATE_OVERRIDE="$state" bash -c '
      trap : CHLD
      # shellcheck disable=SC1090,SC1091
      . "$1/bin/fm-wake-lib.sh"
      fm_recovery_marker_publish "$2/.watcher-down" downtime
    ' _ "$ROOT" "$state" >"$dir/chld.out" 2>"$dir/chld.err" \
      || fail "bash>=5 CHLD recovery publish failed: $(cat "$dir/chld.err")"
    ! grep -F 'unexpected EOF while looking for matching' "$dir/chld.err" >/dev/null \
      || fail "bash>=5 CHLD still hit sibling-\$() parse error: $(cat "$dir/chld.err")"
    generation=$(cut -d: -f3- "$state/.watcher-down")
    case "$generation" in
      ''|*[!A-Za-z0-9._-]*) fail "bash>=5 CHLD mint left empty/invalid generation" ;;
    esac
  fi

  pass "recovery mint and delivery log avoid sibling \$()"
}

test_legacy_generationless_wake_is_adopted() {
  local dir state row sequence generation
  dir=$(make_case legacy-generationless-wake)
  state="$dir/state"
  row=$(printf '1700000000\t7\tcheck\tlegacy-process-event\tcheck: legacy process-event')
  printf '%s\n' "$row" > "$state/.wake-queue"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" \
    || fail "generation-less legacy wake could not be adopted"
  grep -F "$row" "$dir/first.out" >/dev/null \
    || fail "adopted legacy wake was not presented"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/first.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/first.err")
  [ "$sequence" = 7 ] && [ -n "$generation" ] \
    || fail "legacy wake adoption omitted its generation-bound acknowledgement"
  [ "$(cat "$state/.watcher-down" 2>/dev/null || true)" = "pending:handling:$generation" ] \
    || fail "legacy wake was not adopted into durable handling recovery"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/replay.out" 2> "$dir/replay.err" \
    || fail "unacknowledged adopted wake could not be re-drained"
  grep -F "$row" "$dir/replay.out" >/dev/null \
    || fail "unacknowledged adopted wake was lost"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" \
    || fail "adopted legacy wake could not be acknowledged"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged legacy wake remained queued"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/after-ack.out" 2> "$dir/after-ack.err" \
    || fail "post-acknowledgement legacy drain failed"
  ! grep -F "$row" "$dir/after-ack.out" >/dev/null \
    || fail "acknowledged legacy wake was consumed more than once"
  pass "wake drain: generation-less legacy wakes are adopted and acknowledged"
}

# Pin the recovery acknowledgement contract from docs/watcher-continuity.md at
# the queue-library boundary.
# A handover (bin/fm-watch-arm.sh --take-over) undoes only the downtime its own
# watcher stop published over an acknowledged episode. A wake appended between
# the snapshot and the stop, or an episode that was still open, is left for the
# next watcher's arm check to surface.
handover_case() {  # <state> <acked|handling> <append-between 0|1>
  FM_STATE_OVERRIDE="$1" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1/bin/fm-wake-lib.sh"
    marker="$STATE/.watcher-down"
    fm_recovery_marker_publish "$marker" downtime || exit 1
    fm_recovery_marker_read "$marker" || exit 1
    case "$2" in
      acked) fm_recovery_marker_ack "$marker" "${FM_RECOVERY_MARKER_TOKEN##*:}" || exit 1 ;;
      handling) fm_recovery_marker_begin_handling "$marker" || exit 1 ;;
    esac
    fm_recovery_marker_read "$marker" || exit 1
    printf "before=%s\n" "$FM_RECOVERY_MARKER_TOKEN"
    fm_recovery_marker_handover_snapshot "$marker" || exit 1
    [ "$3" = 0 ] || fm_wake_append signal handover "signal: appended during the handover" || exit 1
    # The stopped watcher closes and publishes downtime, as its EXIT cleanup does.
    fm_recovery_marker_publish "$marker" downtime || exit 1
    fm_recovery_marker_handover_restore "$marker" "$FM_RECOVERY_HANDOVER_TOKEN" "$FM_RECOVERY_HANDOVER_SEQ" || exit 1
    fm_recovery_marker_read "$marker" || exit 1
    printf "after=%s\n" "$FM_RECOVERY_MARKER_TOKEN"
  ' _ "$ROOT" "$2" "$3"
}

test_handover_restore_undoes_only_its_own_stop() {
  local out before after
  out=$(handover_case "$(make_case handover-acked)/state" acked 0) || fail "acked handover case failed: $out"
  before=$(printf '%s\n' "$out" | sed -n 's/^before=//p')
  after=$(printf '%s\n' "$out" | sed -n 's/^after=//p')
  case "$before" in acked:downtime:*) ;; *) fail "fixture: the episode was not acknowledged: $out" ;; esac
  [ "$after" = "$before" ] || fail "a handover with nothing queued left a downtime episode: $out"

  out=$(handover_case "$(make_case handover-appended)/state" acked 1) || fail "appended handover case failed: $out"
  before=$(printf '%s\n' "$out" | sed -n 's/^before=//p')
  after=$(printf '%s\n' "$out" | sed -n 's/^after=//p')
  case "$after" in
    pending:downtime:*) [ "${after##*:}" != "${before##*:}" ] || fail "fixture: no fresh episode opened: $out" ;;
    *) fail "a handover hid a wake appended during it: $out" ;;
  esac

  out=$(handover_case "$(make_case handover-handling)/state" handling 0) || fail "handling handover case failed: $out"
  before=$(printf '%s\n' "$out" | sed -n 's/^before=//p')
  after=$(printf '%s\n' "$out" | sed -n 's/^after=//p')
  case "$before" in pending:handling:*) ;; *) fail "fixture: the episode was not being handled: $out" ;; esac
  [ "$after" = "pending:downtime:${before##*:}" ] || fail "a handover rewrote an episode main had not acknowledged: $out"
  pass "a handover undoes only the downtime its own stop published over an acknowledged episode"
}

test_stale_recovery_generation_cannot_touch_a_newer_episode() {
  local dir state first_err replay_err sequence generation handling_marker
  local newer_marker newer_sequence newer_generation rc
  dir=$(make_case stale-recovery-generation)
  state="$dir/state"

  append_wake "$state" check first 'check: first generation' \
    || fail "first generation wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" \
    || fail "first generation drain failed"
  first_err="$dir/first.err"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$first_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$first_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "first drain did not emit a generation-bound acknowledgement"

  append_wake "$state" check second 'check: same episode' \
    || fail "first same-episode wake append failed"
  append_wake "$state" check third 'check: same episode again' \
    || fail "second same-episode wake append failed"
  handling_marker=$(cat "$state/.watcher-down")
  [ "${handling_marker##*:}" = "$generation" ] \
    || fail "repeated publications replaced the outstanding recovery generation"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" > "$dir/handled-ack.out" 2> "$dir/handled-ack.err" \
    || fail "a publication during handling invalidated the printed acknowledgement"
  ! grep "$(printf '\tcheck\tfirst\t')" "$state/.wake-queue" >/dev/null \
    || fail "the handled row was not consumed"
  grep "$(printf '\tcheck\tsecond\t')" "$state/.wake-queue" >/dev/null \
    || fail "a row above the acknowledged sequence was consumed"
  grep "$(printf '\tcheck\tthird\t')" "$state/.wake-queue" >/dev/null \
    || fail "the second row above the acknowledged sequence was consumed"
  case "$(cat "$state/.watcher-down")" in
    pending:*) ;;
    *) fail "an episode with rows still queued was retired" ;;
  esac

  # Retire that episode, then let a genuinely newer one open.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/replay.out" 2> "$dir/replay.err" \
    || fail "remaining wake could not be re-drained"
  replay_err="$dir/replay.err"
  grep "$(printf '\tcheck\tsecond\t')" "$dir/replay.out" >/dev/null \
    || fail "remaining wake did not re-surface"
  grep "$(printf '\tcheck\tthird\t')" "$dir/replay.out" >/dev/null \
    || fail "second remaining wake did not re-surface"
  newer_sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  newer_generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$newer_sequence" \
    --recovery-generation "$newer_generation" \
    || fail "the handled episode could not be acknowledged"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledgement left durable wakes queued"

  append_wake "$state" check fourth 'check: newer recovery generation' \
    || fail "newer generation wake append failed"
  newer_marker=$(cat "$state/.watcher-down")
  [ "${newer_marker##*:}" != "$generation" ] \
    || fail "a retired episode did not open a new recovery generation"

  rc=0
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" > "$dir/stale-ack.out" 2> "$dir/stale-ack.err" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a stale acknowledgement failed instead of degrading safely: $(cat "$dir/stale-ack.err")"
  if ! grep -F 'WAKE_ACK_REQUIRED' "$dir/stale-ack.err" >/dev/null \
    || ! grep -F 're-run' "$dir/stale-ack.err" >/dev/null; then
    fail "a stale acknowledgement did not name its own remedy: $(cat "$dir/stale-ack.err")"
  fi
  [ "$(cat "$state/.watcher-down")" = "$newer_marker" ] \
    || fail "a stale acknowledgement retired the newer recovery episode"
  grep "$(printf '\tcheck\tfourth\t')" "$state/.wake-queue" >/dev/null \
    || fail "a stale acknowledgement consumed the newer durable wake"
  pass "wake drain: a stale acknowledgement cannot retire or consume a newer recovery episode"
}

# An acknowledgement for an EARLIER wake while the current one is still
# presented consumes nothing. That must be said plainly, with the exact command
# for the current wake, because "re-run the drain" re-presents the same row and
# invites the same stale acknowledgement again (the refused-ack loop).
stale_ack_remedy() {  # <stderr-file> -> "<seq>\t<generation>"
  local seq generation
  seq=$(sed -n 's/^wake drain: nothing was acknowledged through [0-9][0-9]*.*run bin\/fm-wake-drain.sh --ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]* after handling it$/\1/p' "$1")
  generation=$(sed -n 's/^wake drain: nothing was acknowledged through [0-9][0-9]*.*run bin\/fm-wake-drain.sh --ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\) after handling it$/\1/p' "$1")
  [ -n "$seq" ] && [ -n "$generation" ] || return 1
  printf '%s\t%s\n' "$seq" "$generation"
}
