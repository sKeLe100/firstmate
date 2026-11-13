#!/usr/bin/env bash
# End-to-end tests for captain-held tasks across secondmate homes: publishing
# and answering holds from a secondmate, reconcile of pending close requests,
# the bound answer channels, the keyed answer intake, legacy identities, origin
# validation, and the record-divergence signal.
#
# Shared harness: tests/fm-captain-hold-lib.sh. Sibling suites:
# tests/fm-captain-hold-lifecycle.test.sh and
# tests/fm-captain-hold-merge-teardown.test.sh.

set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=tests/fm-hold-diagnostics-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-hold-diagnostics-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# shellcheck source=tests/fm-captain-hold-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-lib.sh"

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate fakebin origin json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  fm_test_tasks_toml "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  # A seeded home always carries its parent binding; teardown delivers the
  # scout's final line through it before removing the record.
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  run_captain "$mate" hold sample-release-call --title "Choose the sample release" \
    --reason "captain release choice pending" --repo sample --origin "$origin" >/dev/null \
    || fail "secondmate-owned hold creation failed"
  run_captain "$mate" complete "$origin" sample-release-call >/dev/null \
    || fail "secondmate-owned completion failed"
  # The parent registers the mate before its children are ever torn down;
  # teardown resolves that registration to deliver the scout's final line.
  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null
  grep -Eq "^done \\[key=child-outcome-$origin-done-[0-9a-f]{8}\\] \\[at=[0-9]+\\]: child $origin done: report and visual review complete mode=scout report=data/$origin/report.md$" \
    "$parent/state/sample-mate.status" \
    || fail "the scout's final line did not reach the parent at teardown"

  json=$(run_bearings "$parent") || fail "parent Bearings could not read the secondmate captain call"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold"
      and (.id | endswith("sample-release-call")))
  ' >/dev/null || fail "secondmate captain call did not surface with authoritative owner: $json"
  assert_no_grep "sample-release-call" "$parent/data/backlog.md" "secondmate call leaked into the main backlog"
  assert_grep "sample-release-call" "$mate/data/backlog.md" "secondmate call left its authoritative backlog"
  pass "main-home and secondmate-home captain calls remain correctly routed"
}

# Inside a secondmate home a hold and its answer reach the parent channel from
# the script itself, keyed per hold occurrence, so a re-held task opens and
# closes a distinct parent decision and a retry never duplicates a line. A main
# home publishes nothing anywhere.

test_secondmate_home_publishes_holds_and_answers() {
  local parent mate fakebin channel decision out
  parent=$(make_home parent-channel)
  mate="$TMP_ROOT/channel-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  fm_test_tasks_toml "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'channel-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  channel="$parent/state/channel-mate.status"
  decision="$mate/decision.txt"

  tasks_in "$mate" add quoted-record-call "Choose quoted record handling" --kind ship --repo sample \
    --body 'Documentation quote: Resolution recorded by fm-captain-hold.' >/dev/null \
    || fail "could not create quoted-record captain call"
  run_captain "$mate" hold quoted-record-call --reason "quoted record choice pending" \
    --origin quoted-origin >/dev/null || fail "quoted-record hold failed"
  assert_grep 'needs-decision [key=captain-hold-quoted-record-call-1]: captain hold quoted-record-call: quoted record choice pending' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "body prose was incorrectly counted as a resolution record"

  run_captain "$mate" hold mate-call --title "Choose the mate release" \
    --reason "release choice pending" --repo sample >/dev/null \
    || fail "mate hold failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-1]: captain hold mate-call: release choice pending' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "the mate's hold did not reach the parent channel"
  run_captain "$mate" hold mate-call --reason "release choice pending" >/dev/null \
    || fail "repeated mate hold failed"
  [ "$(grep -c 'captain-hold-mate-call-1' "$channel")" = 1 ] \
    || fail "a repeated hold duplicated the parent decision: $(cat "$channel")"

  printf 'ship it later\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" --release >/dev/null \
    || fail "mate release answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-1]: captain hold mate-call: released' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "the released answer did not close the parent decision"

  run_captain "$mate" hold mate-call --reason "second release choice" >/dev/null \
    || fail "re-hold after release failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-2]: captain hold mate-call: second release choice' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "a re-held task did not open a distinct parent decision"
  printf 'ship it\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "mate close answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-2]: captain hold mate-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "the closing answer did not close the second parent decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "idempotent answer retry failed"
  [ "$(grep -c 'captain-hold-mate-call-2' "$channel")" = 2 ] \
    || fail "an answer retry duplicated a parent line: $(cat "$channel")"
  [ "$(grep -c 'captain-hold-mate-call' "$channel")" = 4 ] \
    || fail "unexpected parent channel contents: $(cat "$channel")"

  run_captain "$mate" hold batch-call --title "Choose the batch release" \
    --reason "batch choice pending" --repo sample >/dev/null \
    || fail "batch hold failed"
  mv "$channel" "$channel.saved"
  mkdir "$channel"
  out=$(printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" 2>&1) \
    || fail "batch answer did not preserve its durable close: $out"
  printf '%s\n' "$out" | grep -Fq 'actionable:' \
    || fail "failed batch parent delivery was not actionable: $out"
  rmdir "$channel"
  mv "$channel.saved" "$channel"
  printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" >/dev/null \
    || fail "idempotent batch answer retry failed"
  [ "$(grep -c 'resolved \[key=captain-hold-batch-call-1\]' "$channel")" = 1 ] \
    || fail "batch retry did not restore exactly one parent resolution: $(cat "$channel")"

  run_captain "$parent" hold main-call --title "Choose the main release" \
    --reason "main choice pending" --repo sample >/dev/null || fail "main hold failed"
  [ ! -e "$parent/state/parent-replies.status" ] || fail "a main home wrote a parent reply"
  assert_no_grep 'captain-hold-main-call' "$channel" "a main home's hold leaked onto a mate channel"
  pass "a secondmate home publishes each hold occurrence and its answer on the parent channel"
}

test_secondmate_reconcile_publishes_before_request_retirement() {
  local parent mate channel evidence out show rc request
  parent=$(make_home reconcile-parent-channel)
  mate=$(make_home reconcile-channel-mate)
  printf 'reconcile-channel-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  channel="$parent/state/reconcile-channel-mate.status"
  evidence="$mate/reconcile-evidence.txt"

  tasks_in "$mate" add reconcile-channel-call "Verify the mate call" --kind ship --repo sample >/dev/null \
    || fail "could not create the reconcile channel call"
  run_captain "$mate" hold reconcile-channel-call --reason "verify current release state" >/dev/null \
    || fail "could not hold the reconcile channel call"
  request_reconciles "$mate" reconcile-board reconcile-channel-call \
    || fail "could not request the channel reconciliation"
  printf 'The release has already landed.\n' > "$evidence"
  request="$mate/state/reconcile-requests/reconcile-channel-call.request"

  chmod 0500 "$mate/state/reconcile-requests"
  set +e
  out=$(run_captain "$mate" reconcile close reconcile-channel-call \
    --evidence-file "$evidence" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$mate/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "failed reconcile request retirement reported success"
  assert_contains "$out" "reconcile-channel-call" \
    "the reconcile retirement failure did not name its task: $out"
  show=$(tasks_in "$mate" show reconcile-channel-call --full)
  assert_contains "$show" "state: done" "request retirement failure reversed the reconciled close"
  assert_contains "$show" "Resolution mode: reconciled" \
    "request retirement failure lost the reconciled resolution mode"
  [ -f "$request" ] || fail "the request retired despite its forced retirement failure"
  [ "$(grep -c 'resolved \[key=captain-hold-reconcile-channel-call-1\]: captain hold reconcile-channel-call: reconciled' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the parent resolution was not published before retirement failed: $(cat "$channel")"

  run_captain "$mate" reconcile close reconcile-channel-call --evidence-file "$evidence" >/dev/null \
    || fail "the closed reconciliation could not finish publication and retirement"
  [ ! -e "$request" ] || fail "the retry did not retire the published reconcile request"
  [ "$(grep -c 'resolved \[key=captain-hold-reconcile-channel-call-1\]: captain hold reconcile-channel-call: reconciled' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the reconciliation retry duplicated or changed its parent resolution: $(cat "$channel")"
  tasks_in "$mate" add answer-channel-call "Answer the mate call" --kind ship --repo sample >/dev/null \
    || fail "could not create the normal-answer channel call"
  run_captain "$mate" hold answer-channel-call --reason "captain answer needed" >/dev/null \
    || fail "could not hold the normal-answer channel call"
  request_reconciles "$mate" reconcile-board answer-channel-call \
    || fail "could not create the normal-answer retry trigger"
  printf 'Proceed with the release.\n' > "$mate/answer.txt"
  request="$mate/state/reconcile-requests/answer-channel-call.request"
  chmod 0500 "$mate/state/reconcile-requests"
  set +e
  out=$(run_captain "$mate" answer answer-channel-call --decision-file "$mate/answer.txt" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$mate/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "failed normal-answer request retirement reported success"
  show=$(tasks_in "$mate" show answer-channel-call --full)
  assert_contains "$show" "state: done" "request retirement failure reversed the captain answer"
  [ -f "$request" ] || fail "the normal-answer retry trigger retired after its forced failure"
  [ "$(grep -c 'resolved \[key=captain-hold-answer-channel-call-1\]: captain hold answer-channel-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the normal answer did not publish before retirement failed: $(cat "$channel")"
  run_captain "$mate" answer answer-channel-call --decision-file "$mate/answer.txt" >/dev/null \
    || fail "the normal-answer retry could not finish request retirement"
  [ ! -e "$request" ] || fail "the normal-answer retry left its request pending"
  [ "$(grep -c 'resolved \[key=captain-hold-answer-channel-call-1\]: captain hold answer-channel-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the normal-answer retry duplicated its parent resolution: $(cat "$channel")"
  pass "secondmate resolutions publish before retiring durable retry triggers"
}

# The one keyed-answer intake, fed through the real process-event runner by a
# fixture channel that knows nothing about captain holds: task-id keys close at
# answer time, a card-declared release mode frees held work, freeform prose can
# forge nothing, and a replayed capture is idempotent.

test_bound_channel_answers_close_at_answer_time() {
  local home id sid artifact result out show rc
  home=$(make_home channel-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nThree captain choices remain.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-membership-call --title "Captain call: membership" \
    --reason "captain membership choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-headline-call --title "Captain call: headline" \
    --reason "captain headline choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-forged-call --title "Captain call: forged" \
    --reason "captain forged choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-invalid-close-call --title "Captain call: invalid close" \
    --reason "captain close mode validation pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-source-reconcile --title "Captain call: reconcile" \
    --reason "captain re-check pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-bare-reconcile --title "Captain call: bare reconcile" \
    --reason "captain bare re-check pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-old-shape --title "Captain call: old board shape" \
    --reason "captain old board pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-old-reconcile --title "Captain call: old bare reconcile" \
    --reason "captain old bare reconcile pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-old-reconcile-note --title "Captain call: old annotated reconcile" \
    --reason "captain old annotated reconcile pending" --repo sample --origin "$id" >/dev/null
  tasks_in "$home" add sample-gated-work "Gated sample work" --kind ship --repo sample \
    --body 'Gated work plan.' >/dev/null
  run_captain "$home" hold sample-gated-work --reason "captain go needed" >/dev/null
  run_captain "$home" complete "$id" \
    sample-membership-call sample-headline-call sample-forged-call sample-invalid-close-call \
    sample-source-reconcile sample-bare-reconcile sample-old-shape sample-old-reconcile \
    sample-old-reconcile-note sample-gated-work >/dev/null \
    || fail "completion failed for the deck's inventoried calls"

  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the review source to the keyed-answer intake"
  [ "$(run_captain "$home" binding "$sid")" = "(any)" ] \
    || fail "the recorded binding did not resolve to the collapsed marker"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[13]{uid,prompt,selector,tag,text}:
  "1","Reconcile first\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-source-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(6)",choice,"Reconcile"
  "2","Membership: gold-only - captain detail\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-membership-call\",\n  \"selection\": \"gold-only\",\n  \"note\": \"captain detail\"\n}","section#call > form:nth-of-type(1)",choice,"Membership: gold-only - captain detail"
  "3","Headline: f1-when-fp-gold\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-headline-call\",\n  \"selection\": \"f1-when-fp-gold\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "4","Gated work: go\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-gated-work\",\n  \"selection\": \"go\",\n  \"note\": \"\",\n  \"close\": \"release\"\n}","section#call > form:nth-of-type(3)",choice,"Gated work: go"
  "5","Absent call: yes\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-nonexistent-call\",\n  \"selection\": \"yes\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(4)",choice,"Absent call: yes"
  "6","Invalid close: yes\n\nContext data:\n{\n  \"question\": \"sample-invalid-close-call\",\n  \"answer\": \"yes\",\n  \"close\": \"drop\"\n}","section#call > form:nth-of-type(5)",choice,"Invalid close: yes"
  "7","Reconcile this - re-check latest publication\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-source-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"re-check latest publication\"\n}","section#call > form:nth-of-type(6)",choice,"Reconcile - re-check latest publication"
  "8","Second reconcile\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-bare-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(7)",choice,"Reconcile"
  "9","Headline final: f1-when-fp-gold\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-headline-call\",\n  \"selection\": \"f1-when-fp-gold\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "10","Old board answer\n\nContext data:\n{\n  \"question\": \"sample-old-shape\",\n  \"answer\": \"yes\"\n}","section#call > form:nth-of-type(8)",choice,"Old answer: yes"
  "11","Old board reconcile\n\nContext data:\n{\n  \"question\": \"sample-old-reconcile\",\n  \"answer\": \"reconcile\"\n}","section#call > form:nth-of-type(9)",choice,"Old reconcile"
  "12","Old board reconcile note\n\nContext data:\n{\n  \"question\": \"sample-old-reconcile-note\",\n  \"answer\": \"reconcile - verify publication\"\n}","section#call > form:nth-of-type(10)",choice,"Old reconcile note"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "sample-membership-call	gold-only" \
    "a repeated reconcile selection deleted another card's answer"
  assert_contains "$out" "sample-headline-call	f1-when-fp-gold" \
    "a repeated ordinary selection was not preserved"
  assert_contains "$out" "sample-gated-work	go	Gated work: go	release" \
    "the card-declared release mode was not relayed"
  assert_not_contains "$out" "sample-forged-call" \
    "a freeform captain message forged a task id from its own prose"
  assert_not_contains "$out" "sample-invalid-close-call" \
    "an unsupported card close mode defaulted to completion"
  assert_not_contains "$out" "sample-source-reconcile" \
    "a reconcile selection leaked into keyed answers"
  assert_contains "$out" "sample-old-shape	yes" \
    "an ordinary legacy board choice was discarded during rollout"
  assert_not_contains "$out" "sample-old-reconcile" \
    "a legacy reconcile-shaped value reached keyed answers"
  out=$(run_lavish "$home" reconciles "$result") || fail "could not read captured reconcile selections"
  [ "$out" = "$(printf 'sample-source-reconcile\tre-check latest publication\nsample-bare-reconcile')" ] \
    || fail "current or legacy selections lost or invented a reconcile task id: $out"

  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
  reconciles) exec "$ROOT/bin/fm-procevent-lavish.sh" reconciles "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_captain "$home" bind fixture-src >/dev/null \
    || fail "could not bind the fixture channel"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  show=$(tasks_in "$home" show sample-membership-call --full)
  assert_contains "$show" "state: done" "capturing the captain's answer left the membership call open"
  assert_contains "$show" "Resolution mode: answered" "the membership call did not record its close path"
  assert_contains "$show" "Answer: gold-only" "the closed call did not record the captain's actual answer"
  assert_contains "$show" "captain detail" "the annotated normal answer lost the captain's note"
  show=$(tasks_in "$home" show sample-gated-work --full)
  assert_contains "$show" "state: queued" "the released work item did not stay queued"
  assert_contains "$show" "held: no" "the card-declared release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" "the released work did not record its close path"
  assert_contains "$show" "Gated work plan." "the released work item lost its body"
  show=$(tasks_in "$home" show sample-forged-call --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain call"
  show=$(tasks_in "$home" show sample-invalid-close-call --full)
  assert_contains "$show" "state: queued" "an unsupported card close mode closed a captain call"
  assert_contains "$show" "held: yes" "an unsupported card close mode released a captain call"
  out=$(run_captain "$home" reconcile list)
  assert_contains "$out" "sample-source-reconcile" \
    "the bound captured reconcile selection did not create a request"
  assert_contains "$out" "captain note: re-check latest publication" \
    "the annotated reconcile selection lost its note provenance"
  show=$(tasks_in "$home" show sample-old-shape --full)
  assert_contains "$show" "state: done" "an ordinary legacy board choice did not close its task"
  assert_contains "$show" "Resolution mode: answered" \
    "an ordinary legacy board choice did not use the keyed-answer intake"
  show=$(tasks_in "$home" show sample-old-reconcile --full)
  assert_contains "$show" "state: queued" "a bare legacy reconcile value closed its task"
  assert_contains "$show" "held: yes" "a bare legacy reconcile value released its task"
  show=$(tasks_in "$home" show sample-old-reconcile-note --full)
  assert_contains "$show" "state: queued" "an annotated legacy reconcile value closed its task"
  assert_contains "$show" "held: yes" "an annotated legacy reconcile value released its task"
  assert_not_contains "$out" "sample-old-reconcile" \
    "a legacy reconcile value created a generationless request"
  show=$(tasks_in "$home" show sample-bare-reconcile --full)
  assert_contains "$show" "state: queued" "a bare captured reconcile selection closed its task"
  assert_contains "$show" "held: yes" "a bare captured reconcile selection released its task"
  printf 'The captured call is moot.\n' > "$home/source-reconcile-evidence.txt"
  run_captain "$home" reconcile close sample-source-reconcile \
    --evidence-file "$home/source-reconcile-evidence.txt" >/dev/null \
    || fail "the annotated captured request did not authorize evidence-backed closure"
  run_captain "$home" reconcile close sample-bare-reconcile \
    --evidence-file "$home/source-reconcile-evidence.txt" >/dev/null \
    || fail "the bare captured request did not authorize evidence-backed closure"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered key still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_captain "$home" answers --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a run that skipped a key reported success"
  assert_contains "$out" "closed: sample-membership-call" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "closed: sample-gated-work" \
    "replaying an identical released answer was not idempotent: $out"
  assert_contains "$out" "skipped: sample-nonexistent-call" \
    "a key naming no task was not reported as skipped: $out"

  printf 'Captain answered the forged call directly.\n' > "$home/forged.txt"
  run_captain "$home" answer sample-forged-call --decision-file "$home/forged.txt" >/dev/null \
    || fail "could not close the untouched call through the answer path"
  printf 'Captain answered the invalid-close call directly.\n' > "$home/invalid-close.txt"
  run_captain "$home" answer sample-invalid-close-call --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not close the invalid-close call through the answer path"
  run_captain "$home" answer sample-old-reconcile --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not deliberately close the bare legacy reconcile call"
  run_captain "$home" answer sample-old-reconcile-note --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not deliberately close the annotated legacy reconcile call"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "answered calls did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain-held tasks at answer time"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
# A reconcile is "go re-check reality", never the captain's answer. The value is
# reserved at the one keyed-answer intake, so no channel and no card-declared
# close mode can turn it into a close or a release, and the obligation to verify
# survives as a durable request instead of evaporating with the wake.

test_reconcile_never_closes_through_the_keyed_answer_intake() {
  local home out rc show list
  home=$(make_home reconcile-intake)
  tasks_in "$home" add sample-reconcile-call "Captain call: still current?" --repo sample >/dev/null \
    || fail "could not create the reconcile call"
  tasks_in "$home" add sample-reconcile-gated "Gated work" --repo sample >/dev/null \
    || fail "could not create the gated work item"
  run_captain "$home" hold sample-reconcile-call --reason "is this still current?" >/dev/null \
    || fail "could not hold the reconcile call"
  run_captain "$home" hold sample-reconcile-gated --reason "waiting on the captain" >/dev/null \
    || fail "could not hold the gated work item"

  set +e
  out=$(printf 'sample-reconcile-call\treconcile\tReconcile\n%s\n' \
    "$(printf 'sample-reconcile-gated\treconcile\tReconcile\trelease')" \
    | run_captain "$home" answers --source "captain chat" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the shared answer intake accepted reconcile as an answer"
  assert_contains "$out" "refused: sample-reconcile-call" \
    "the shared intake did not visibly refuse reconcile: $out"
  case "$out" in
    *"closed: sample-reconcile"*) fail "a reconcile row closed a captain call: $out" ;;
  esac

  show=$(tasks_in "$home" show sample-reconcile-call --full)
  assert_contains "$show" "state: queued" "a reconcile row completed a captain call"
  assert_contains "$show" "held: yes" "a reconcile row released a captain call"
  case "$show" in
    *"Resolution recorded by"*) fail "a reconcile row wrote a resolution record" ;;
  esac
  show=$(tasks_in "$home" show sample-reconcile-gated --full)
  assert_contains "$show" "held: yes" "a release-mode reconcile row lifted a captain hold"

  list=$(run_captain "$home" reconcile list) || fail "could not list the reconcile requests"
  assert_contains "$list" "reconcile-requests: 0" \
    "the shared answer intake created a reconcile request: $list"
  set +e
  out=$(printf 'sample-reconcile-call\n' \
    | run_captain "$home" reconcile-requests --source-id unbound-src --source "captured board" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound captured source created a reconcile request"
  request_reconciles "$home" board-src sample-reconcile-call sample-reconcile-gated \
    || fail "the bound captured source did not create reconcile requests"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "sample-reconcile-call" "the reconcile obligation was not recorded durably: $list"
  assert_contains "$list" "reconcile-requests: 2" "the reconcile requests were not both recorded: $list"

  request_reconciles "$home" board-src sample-reconcile-call \
    || fail "replaying a captured reconcile selection failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 2" "a replayed reconcile selection duplicated the obligation: $list"
  pass "only a bound captured source creates reconcile requests"
}

test_normal_answers_retire_pending_reconcile_requests() {
  local home list id
  home=$(make_home reconcile-normal-answer)
  for id in sample-direct-close sample-direct-release sample-keyed-close; do
    tasks_in "$home" add "$id" "Captain call $id" --repo sample >/dev/null
    run_captain "$home" hold "$id" --reason "waiting for the captain" >/dev/null
  done
  request_reconciles "$home" board-src sample-direct-close sample-direct-release sample-keyed-close \
    || fail "could not create reconcile requests before normal answers"

  printf 'Captain said close.\n' > "$home/close.txt"
  printf 'Captain said release.\n' > "$home/release.txt"
  run_captain "$home" answer sample-direct-close --decision-file "$home/close.txt" >/dev/null \
    || fail "a direct close answer failed"
  run_captain "$home" answer sample-direct-release --decision-file "$home/release.txt" --release >/dev/null \
    || fail "a direct release answer failed"
  printf 'sample-keyed-close\tyes\tYes\n' \
    | run_captain "$home" answers --source "board sequence 2" >/dev/null \
    || fail "a keyed normal answer failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" \
    "normal answers left stranded reconcile requests: $list"

  run_captain "$home" answer sample-direct-close --decision-file "$home/close.txt" >/dev/null \
    || fail "a direct close replay failed"
  run_captain "$home" answer sample-direct-release --decision-file "$home/release.txt" --release >/dev/null \
    || fail "a direct release replay failed"
  printf 'sample-keyed-close\tyes\tYes\n' \
    | run_captain "$home" answers --source "board sequence 2" >/dev/null \
    || fail "a keyed answer replay failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" \
    "an idempotent normal-answer replay restored a reconcile request: $list"
  pass "normal answers and their replays retire reconcile requests"
}

# The two verification outcomes, and the honesty of the record each writes.

test_reconcile_closes_with_evidence_or_keeps_the_call_open() {
  local home show list rc out
  home=$(make_home reconcile-outcomes)
  tasks_in "$home" add sample-moot-call "Captain call: ship 0.1.37?" --repo sample >/dev/null
  tasks_in "$home" add sample-active-call "Captain call: which admission order?" --repo sample >/dev/null
  tasks_in "$home" add sample-mode-call "Captain call: verify replay mode?" --repo sample >/dev/null
  run_captain "$home" hold sample-moot-call --reason "ship 0.1.37?" >/dev/null
  run_captain "$home" hold sample-active-call --reason "which admission order?" >/dev/null
  run_captain "$home" hold sample-mode-call --reason "verify replay mode?" >/dev/null
  printf '0.1.38 was published on 2026-09-05, so the 0.1.37 question is moot.\n' > "$home/evidence.txt"
  printf 'Still open: nothing has shipped and the choice is unchanged.\n' > "$home/note.txt"

  set +e
  out=$(run_captain "$home" reconcile close sample-moot-call --evidence-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reconcile closed a call without a pending board request"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the ungated close refusal did not name the missing board request: $out"
  set +e
  out=$(run_captain "$home" reconcile note sample-active-call --note-file "$home/note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reconcile annotated a call without a pending board request"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the ungated note refusal did not name the missing board request: $out"

  request_reconciles "$home" board-src sample-moot-call sample-active-call sample-mode-call \
    || fail "could not file the reconcile requests"

  set +e
  out=$(run_captain "$home" reconcile close sample-moot-call 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reconcile close was accepted with no evidence"
  assert_contains "$out" "evidence" "the refusal did not name the missing evidence: $out"

  cp "$home/state/reconcile-requests/sample-mode-call.request" "$home/mode-request.backup"
  run_captain "$home" answer sample-mode-call --decision-file "$home/evidence.txt" >/dev/null \
    || fail "could not record the normal answer for the mode fixture"
  cp "$home/mode-request.backup" "$home/state/reconcile-requests/sample-mode-call.request"
  set +e
  out=$(run_captain "$home" reconcile close sample-mode-call --evidence-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a normal captain answer replayed as a reconciliation"
  assert_contains "$out" "was not closed by reconciliation" \
    "the reconcile replay refusal did not identify the incompatible resolution mode: $out"
  run_captain "$home" answer sample-mode-call --decision-file "$home/evidence.txt" >/dev/null \
    || fail "the normal answer replay did not retire its restored pending request"

  run_captain "$home" reconcile close sample-moot-call --evidence-file "$home/evidence.txt" >/dev/null \
    || fail "could not close the moot call with evidence"
  show=$(tasks_in "$home" show sample-moot-call --full)
  assert_contains "$show" "state: done" "the moot call did not close"
  assert_contains "$show" "Resolution mode: reconciled" "the moot call did not record how it closed"
  assert_contains "$show" "Reconciliation evidence:" "the moot call did not record the evidence"
  assert_contains "$show" "0.1.38 was published" "the recorded evidence was lost"
  case "$show" in
    *"Captain decision:"*) fail "a reconciled close was recorded as the captain's own words" ;;
  esac
  set +e
  out=$(run_captain "$home" answer sample-moot-call --decision-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reconciled resolution replayed as a captain answer"
  assert_contains "$out" "not a captain-answer replay" \
    "the answer replay refusal did not identify the incompatible resolution mode: $out"

  run_captain "$home" reconcile note sample-active-call --note-file "$home/note.txt" >/dev/null \
    || fail "could not annotate the still-active call"
  show=$(tasks_in "$home" show sample-active-call --full)
  assert_contains "$show" "state: queued" "annotating a still-active call closed it"
  assert_contains "$show" "held: yes" "annotating a still-active call released it"
  assert_contains "$show" "Captain hold reconciled:" "the re-check left no dated note"
  assert_contains "$show" "Still open: nothing has shipped" "the note body was lost"
  case "$show" in
    *"Resolution recorded by"*) fail "annotating a still-active call wrote a resolution record" ;;
  esac
  set +e
  out=$(run_captain "$home" reconcile note sample-active-call --note-file "$home/note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a retired reconcile request appended a duplicate note"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the duplicate-note refusal did not name the retired request: $out"

  printf 'sample-active-call\n' \
    | FM_CAPTAIN_HOLD_NOW=2026-09-07T06:00:00Z run_captain "$home" reconcile-requests \
        --source-id board-src --source "captured board result sequence 2" >/dev/null \
    || fail "could not create the second reconcile request"
  FM_CAPTAIN_HOLD_NOW=2026-09-07T06:01:00Z run_captain "$home" reconcile note sample-active-call \
    --note-file "$home/note.txt" >/dev/null \
    || fail "the second request with the same finding was not recorded"
  show=$(tasks_in "$home" show sample-active-call --full)
  [ "$(printf '%s\n' "$show" | grep -o 'Captain hold reconciled:' | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "a later reconcile request with the same note did not append its own record"
  assert_contains "$show" "Captain hold reconciled: 2026-09-07T06:01:00Z" \
    "the second reconcile request lost its own dated note"

  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "the verified requests were not retired: $list"
  pass "reconcile closes a moot call with evidence and keeps an active one open with a note"
}

test_reconcile_outcomes_retry_partial_failures_once() {
  local home out show list rc
  home=$(make_home reconcile-partial-retry)
  tasks_in "$home" add sample-reconcile-close-retry "Close retry" --repo sample >/dev/null
  tasks_in "$home" add sample-reconcile-note-retry "Note retry" --repo sample >/dev/null
  tasks_in "$home" add sample-reconcile-retire-retry "Retire retry" --repo sample >/dev/null
  tasks_in "$home" add sample-reconcile-close-retire "Close retire" --repo sample >/dev/null
  tasks_in "$home" add sample-answer-retire "Answer retire" --repo sample >/dev/null
  run_captain "$home" hold sample-reconcile-close-retry --reason "verify close" >/dev/null
  run_captain "$home" hold sample-reconcile-note-retry --reason "verify note" >/dev/null
  run_captain "$home" hold sample-reconcile-retire-retry --reason "verify retire" >/dev/null
  run_captain "$home" hold sample-reconcile-close-retire --reason "verify close retirement" >/dev/null
  run_captain "$home" hold sample-answer-retire --reason "verify answer retirement" >/dev/null
  request_reconciles "$home" board-src sample-reconcile-close-retry sample-reconcile-note-retry \
    sample-reconcile-retire-retry sample-reconcile-close-retire sample-answer-retire \
    || fail "could not create partial-retry requests"
  printf 'Verified moot.\n' > "$home/retry-evidence.txt"
  printf 'Verified active.\n' > "$home/retry-note.txt"
  printf 'Verified retirement retry.\n' > "$home/retry-retire-note.txt"
  printf 'Verified close retirement.\n' > "$home/close-retire-evidence.txt"
  printf 'Captain answered despite retirement failure.\n' > "$home/answer-retire.txt"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ "${2:-}" = sample-reconcile-close-retry ] \
  && [ ! -e "$FM_HOME/reconcile-close-failed" ]; then
  : > "$FM_HOME/reconcile-close-failed"
  exit 92
fi
if [ "${1:-}" = update ] && [ "${2:-}" = sample-reconcile-note-retry ]; then
  "$REAL_TASKS_AXI" "$@" || exit $?
  : > "$FM_HOME/reconcile-note-updated"
  exit 0
fi
if [ "${1:-}" = show ] && [ "${2:-}" = sample-reconcile-note-retry ] \
  && [ -e "$FM_HOME/reconcile-note-updated" ] && [ ! -e "$FM_HOME/reconcile-note-show-failed" ]; then
  : > "$FM_HOME/reconcile-note-show-failed"
  exit 93
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  set +e
  out=$(run_captain "$home" reconcile close sample-reconcile-close-retry \
    --evidence-file "$home/retry-evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the forced reconcile close failure reported success"
  run_captain "$home" reconcile close sample-reconcile-close-retry \
    --evidence-file "$home/retry-evidence.txt" >/dev/null \
    || fail "reconcile close did not recover from its partial failure"
  show=$(tasks_in "$home" show sample-reconcile-close-retry --full)
  [ "$(printf '%s\n' "$show" | grep -c 'Resolution mode: reconciled')" -eq 1 ] \
    || fail "reconcile close duplicated its resolution record on retry"

  set +e
  out=$(run_captain "$home" reconcile note sample-reconcile-note-retry \
    --note-file "$home/retry-note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the forced post-note probe failure reported success"
  set +e
  out=$(run_captain "$home" reconcile note sample-reconcile-note-retry \
    --note-file "$home/retry-note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a note retry succeeded after the request was retired"
  show=$(tasks_in "$home" show sample-reconcile-note-retry --full)
  [ "$(printf '%s\n' "$show" | grep -c 'Captain hold reconciled:')" -eq 1 ] \
    || fail "reconcile note duplicated its durable annotation"

  chmod 0500 "$home/state/reconcile-requests"
  set +e
  out=$(run_captain "$home" reconcile close sample-reconcile-close-retire \
    --evidence-file "$home/close-retire-evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a failed close request retirement reported success"
  assert_contains "$out" "sample-reconcile-close-retire" \
    "the close retirement failure did not name its task: $out"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "sample-reconcile-close-retire" \
    "the failed close retirement hid its pending request"
  chmod 0700 "$home/state/reconcile-requests"
  run_captain "$home" reconcile close sample-reconcile-close-retire \
    --evidence-file "$home/close-retire-evidence.txt" >/dev/null \
    || fail "the closed reconciliation could not finish request retirement"

  chmod 0500 "$home/state/reconcile-requests"
  set +e
  out=$(run_captain "$home" answer sample-answer-retire \
    --decision-file "$home/answer-retire.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a failed answer-boundary retirement reported success"
  show=$(tasks_in "$home" show sample-answer-retire --full)
  assert_contains "$show" "state: done" "retirement failure reversed the durable captain answer"
  assert_contains "$show" "Captain answered despite retirement failure" \
    "retirement failure lost the durable captain answer"
  chmod 0700 "$home/state/reconcile-requests"
  run_captain "$home" answer sample-answer-retire --decision-file "$home/answer-retire.txt" >/dev/null \
    || fail "the answer replay could not finish request retirement"

  chmod 0500 "$home/state/reconcile-requests"
  set +e
  out=$(run_captain "$home" reconcile note sample-reconcile-retire-retry \
    --note-file "$home/retry-retire-note.txt" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$home/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "a failed request retirement reported note success"
  assert_not_contains "$out" "still-open:" "failed retirement reported a successful outcome"
  run_captain "$home" reconcile note sample-reconcile-retire-retry \
    --note-file "$home/retry-retire-note.txt" >/dev/null \
    || fail "the applied note could not finish request retirement on retry"
  show=$(tasks_in "$home" show sample-reconcile-retire-retry --full)
  [ "$(printf '%s\n' "$show" | grep -c 'Captain hold reconciled:')" -eq 1 ] \
    || fail "failed request retirement duplicated the reconcile note"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "partial retries left a reconcile request pending"
  pass "reconcile outcomes apply durable mutations once across partial failures"
}

test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-only-call --title "Captain call: only choice" \
    --reason "captain only choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the unbound call"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"sample-only-call\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_captain "$home" binding "$sid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a binding"
  [ -z "$out" ] || fail "an unbound source printed a binding: $out"
  show=$(tasks_in "$home" show sample-only-call --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain call"
  assert_contains "$show" "held: yes" "an unbound review released a captain call"
  pass "a channel source with no decision binding closes nothing"
}

# Everything a pre-collapse install already has keeps working: composed
# identities through the shim, short decision keys in recorded metadata, a
# concrete-origin binding, and the chat fallback for old rows.

test_legacy_identities_keep_working() {
  local home id hold out show legacy_text legacy_digest old_hold
  home=$(make_home legacy-compat)
  id=sample-legacy-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Legacy-shaped review" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Legacy review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"

  hold=$(run_shim "$home" id "$id" pick-one)
  [ "$hold" = "$id-decision-pick-one" ] || fail "the shim identity was not deterministic: $hold"
  out=$(run_shim "$home" hold "$id" pick-one \
    --title "Pick one" --reason "captain choice pending" --repo sample) \
    || fail "the shim hold path failed"
  [ "$out" = "$hold" ] || fail "the shim hold did not print the composed identity: $out"
  run_shim "$home" hold "$id" keep-two \
    --title "Keep two" --reason "captain second choice pending" --repo sample >/dev/null \
    || fail "the shim second hold failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: captain" "the shim-created row is not a plain captain-held task"

  # A pre-collapse metadata attestation records SHORT keys; verify must resolve
  # them through the legacy composed identity.
  printf 'decisions_reviewed=1\ndecision_keys=keep-two,pick-one\n' >> "$home/state/$id.meta"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "legacy short-key metadata did not verify against composed identities"

  # The shim's routed close records the routed work inside the captain decision
  # and clears the recorded edge.
  tasks_in "$home" add sample-legacy-work "Apply the legacy choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  tasks_in "$home" add sample-unrouted-work "Unrouted legacy work" \
    --kind ship --repo sample >/dev/null
  printf 'Use route north.\n' > "$home/route.txt"
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-missing-work > "$home/missing-route.out" 2> "$home/missing-route.err"; then
    fail "the shim resolve accepted a missing routed task"
  fi
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-unrouted-work > "$home/unrouted.out" 2> "$home/unrouted.err"; then
    fail "the shim resolve accepted work not blocked by the legacy decision"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "invalid shim routing closed the legacy decision"
  assert_not_contains "$show" "Resolution recorded" "invalid shim routing recorded an answer"
  run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-legacy-work >/dev/null \
    || fail "the shim resolve path failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the shim resolve did not close the row"
  assert_contains "$show" "Use route north." "the shim resolve lost the captain decision"
  assert_contains "$show" "- sample-legacy-work" "the shim resolve lost the routed identities"
  show=$(tasks_in "$home" show sample-legacy-work --full)
  assert_contains "$show" "blocked: no" "the shim resolve did not release the routed work"

  old_hold=$(run_shim "$home" hold "$id" old-route \
    --title "Old routed choice" --reason "captain old route pending" --repo sample)
  tasks_in "$home" add sample-old-routed-work "Apply the old routed choice" \
    --kind ship --repo sample --blocked-by "$old_hold" >/dev/null
  printf 'Use the historical route.\n' > "$home/old-route.txt"
  legacy_text=$(cat "$home/old-route.txt")
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: sample-old-routed-work\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-old-routed-work\n' \
    "$legacy_digest" "$legacy_text" > "$home/old-route-body.txt"
  tasks_in "$home" update "$old_hold" --body-file "$home/old-route-body.txt" --archive-body >/dev/null
  run_shim "$home" resolve "$id" old-route --decision-file "$home/old-route.txt" \
    --routed-to sample-old-routed-work >/dev/null \
    || fail "the shim did not replay a matching pre-collapse routed record"
  show=$(tasks_in "$home" show "$old_hold" --full)
  assert_contains "$show" "state: done" "the replayed legacy resolve did not close its hold"
  show=$(tasks_in "$home" show sample-old-routed-work --full)
  assert_contains "$show" "blocked_by: none" "the replayed legacy resolve did not clear its recorded edge"

  # The shim decline path maps onto the same recorded answer.
  printf 'Declined: keep the current shape.\n' > "$home/decline.txt"
  run_shim "$home" decline "$id" keep-two --decision-file "$home/decline.txt" >/dev/null \
    || fail "the shim decline path failed"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "shim-closed rows did not satisfy the completion gate"

  # A concrete-origin binding (a pre-collapse record) makes short channel keys
  # resolve through the composed identity.
  run_shim "$home" hold "$id" third-choice \
    --title "Third choice" --reason "captain third choice pending" --repo sample >/dev/null
  run_shim "$home" bind legacy-src "$id" >/dev/null || fail "the shim bind path failed"
  [ "$(run_captain "$home" binding legacy-src)" = "$id" ] \
    || fail "the concrete-origin binding was not preserved"
  printf 'third-choice\toption b\t\n' \
    | run_captain "$home" answers "$(run_captain "$home" binding legacy-src)" \
        --source "legacy channel" >/dev/null \
    || fail "a short key did not resolve through the concrete-origin binding"
  show=$(tasks_in "$home" show "$id-decision-third-choice" --full)
  assert_contains "$show" "state: done" "the legacy-keyed answer did not close its row"

  run_shim "$home" hold "$id" fourth-choice \
    --title "Fourth choice" --reason "captain fourth choice pending" --repo sample >/dev/null
  legacy_text=$(printf 'Captain answered this decision through legacy replay.\nDecision key: fourth-choice\nAnswer: option c\n')
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: none\nResolution mode: answered\n\nCaptain decision:\n%s\n' \
    "$legacy_digest" "$legacy_text" > "$home/legacy-body.txt"
  tasks_in "$home" update "$id-decision-fourth-choice" --body-file "$home/legacy-body.txt" --archive-body >/dev/null
  tasks_in "$home" "done" "$id-decision-fourth-choice" >/dev/null
  out=$(printf 'fourth-choice\toption c\t\n' \
    | run_captain "$home" answers "$id" --source "legacy replay") \
    || fail "an identical pre-collapse keyed answer was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the pre-collapse keyed answer digest was treated as drift"
  out=$(printf '%s-decision-fourth-choice\toption c\t\n' "$id" \
    | run_captain "$home" answers --source "legacy replay") \
    || fail "a full legacy task-id replay without an origin was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the origin-free legacy replay digest was treated as drift"
  pass "legacy identities, metadata, bindings, and the shim keep working"
}

# A board answer must reach the keyed-answer intake through the RUNNER, not just
# through a hand-fed `answers` call. The captain answered ten calls on a bearings
# board, the board accepted them, and nothing collected them: the source that
# collects a board is a supervised process, and while it was not running the
# board went on presenting as armed. Everything between the captured result and
# the closed task is asserted here end to end - capture, the wake that tells
# firstmate to look, and the recorded answer - because each of those was intact
# on its own while the chain as a whole delivered nothing.

test_board_answer_reaches_the_keyed_answer_intake() {
  local home sid stub out queue show
  home=$(make_home board-channel)
  sid=lavish-b0a4d0000000f1e2
  fm_test_track_procevent_home "$home" "$home/procevent-claims"

  run_captain "$home" hold sample-board-call --title "Choose the sample board route" \
    --reason "captain board route choice pending" --repo sample >/dev/null \
    || fail "could not register the board call"

  # One published Lavish poll response carrying the captain's structured answer,
  # in the shape the adapter's own reader parses: a declared field order, an
  # indented CSV row, and the versioned answer context inside its prompt.
  stub="$home/board-source.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
cat <<'OUT'
session:
  status: feedback
  session_ended: false
prompts[1]{tag,text,prompt}:
  "choice","Take the north route","Context data: {\"schema\":\"fm-bearings-answer.v1\",\"question\":\"sample-board-call\",\"selection\":\"north\",\"note\":\"\"}"
OUT
SH
  chmod +x "$stub"

  run_procevent "$home" register lavish "$sid" -- "$stub" >/dev/null \
    || fail "could not register the board source"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the board source to the keyed-answer intake"

  out=$(run_procevent "$home" start "$sid" 2>&1) \
    || fail "the board source runner did not complete: $out"
  assert_contains "$out" "$sid.1.result" "the board answer was never durably captured: $out"
  assert_contains "$out" "answers-fed: $sid" \
    "the captured board answer never reached the keyed-answer intake: $out"

  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" "check: procevent lavish $sid 1" \
    "the captured board answer produced no wake: $queue"

  show=$(tasks_in "$home" show sample-board-call --full)
  assert_contains "$show" "state: done" "the board answer did not close the captain call"
  assert_contains "$show" "north" "the board answer lost the captain's selection"
  assert_contains "$show" "the captured result $sid sequence 1" \
    "the recorded answer did not name the board result that carried it"
  pass "a board answer reaches the keyed-answer intake and wakes firstmate"
}

# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does - for a task-id key, and for a legacy composed identity.

test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id fb show list
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"
  run_shim "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample >/dev/null \
    || fail "could not register the legacy chat row"
  run_captain "$home" hold sample-chat-followup --title "Choose the chat follow-up" \
    --reason "captain follow-up choice pending" --repo sample >/dev/null \
    || fail "could not register the task-id chat call"
  run_captain "$home" hold sample-chat-reconcile --title "Reconcile from chat" \
    --reason "captain chat reconcile pending" --repo sample >/dev/null \
    || fail "could not register the chat reconcile call"
  run_captain "$home" complete "$id" "$id-decision-chat-choice" sample-chat-followup \
    sample-chat-reconcile >/dev/null \
    || fail "completion failed for the chat calls"
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its durable owner"

  fb="$home/fakebin"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred legacy decision was refused by the chat channel"
  # The answer rides fm-send's durable inbox plane: the record carries the
  # text while the typed channel carries only the doorbell.
  grep -qF "go with option A" "$home/state/$id.inbox/001.msg" \
    || fail "the answer text never reached the worker's durable inbox record"
  show=$(tasks_in "$home" show "$id-decision-chat-choice" --full)
  assert_contains "$show" "state: done" "a chat answer left the legacy row open"
  assert_contains "$show" "Answer: go with option A" "the chat-answered row lost the captain answer"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "take the second option" >/dev/null 2>&1 \
    || fail "an answer keyed by a task id was refused by the chat channel"
  show=$(tasks_in "$home" show sample-chat-followup --full)
  assert_contains "$show" "state: done" "a chat answer left the task-id call open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered call did not record its close path"
  assert_contains "$show" "Answer: take the second option" "the chat-answered call lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered call lost its channel provenance"

  : > "$home/send.log"
  set +e
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-reconcile reconcile >/dev/null 2>&1
  set -e
  show=$(tasks_in "$home" show sample-chat-reconcile --full)
  assert_contains "$show" "state: queued" "a chat reconcile answer closed the call"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "a chat reconcile answer created a board request"
  printf 'Chat cannot authorize this closure.\n' > "$home/chat-reconcile.txt"
  if run_captain "$home" reconcile close sample-chat-reconcile \
    --evidence-file "$home/chat-reconcile.txt" >/dev/null 2>&1; then
    fail "a chat reconcile answer authorized evidence-backed closure"
  fi
  run_captain "$home" answer sample-chat-reconcile --decision-file "$home/chat-reconcile.txt" >/dev/null \
    || fail "could not close the chat reconcile fixture normally"

  if env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "again" \
    > "$home/closed-key.out" 2> "$home/closed-key.err"; then
    fail "a key already closed in both ledgers was accepted"
  fi
  run_captain "$home" verify "$id" >/dev/null \
    || fail "chat-answered calls did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}

test_origin_slug_validation_precedes_path_construction() {
  local home
  home=$(make_home slug-validation)
  if run_captain "$home" complete "../escape" --none > "$home/escape.out" 2> "$home/escape.err"; then
    fail "complete accepted a path-escaping origin id"
  fi
  assert_grep "privacy-safe slug" "$home/escape.err" "the refusal must name the slug contract"
  if run_captain "$home" verify "../escape" > "$home/escape-verify.out" 2> "$home/escape-verify.err"; then
    fail "verify accepted a path-escaping origin id"
  fi
  if run_captain "$home" hold "bad id" --title "x" --reason "y" > "$home/bad-hold.out" 2> "$home/bad-hold.err"; then
    fail "hold accepted an invalid task id"
  fi
  pass "completion and verification validate origins before constructing paths"
}

# --- record divergence ------------------------------------------------------

test_status_resolution_over_an_open_hold_is_signalled() {
  local home id out drain
  home=$(make_home divergence-signalled)
  id=sample-route-review
  tasks_in "$home" add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north or south" --reason "captain route choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the collapsed-identity captain call"
  run_captain "$home" hold "$id-decision-access" \
    --title "Open or restricted sample access" --reason "captain access choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the legacy-identity captain call"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-route-call]: north or south
resolved [key=sample-route-call]: answered: north
needs-decision [key=access]: open or restricted sample access
resolved [key=access]: answered: restricted
done: report complete
EOF

  out=$(run_captain "$home" diverged) || fail "diverged failed on the reconstructed loss"
  printf '%s\n' "$out" | grep -F "sample-route-call	$id	sample-route-call" >/dev/null \
    || fail "the collapsed-identity divergence was not signalled: $out"
  printf '%s\n' "$out" | grep -F "$id-decision-access	$id	access" >/dev/null \
    || fail "the legacy-identity divergence was not signalled: $out"

  drain=$(run_drain "$home") || fail "the drain failed while reporting divergence"
  printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null \
    || fail "the divergence never reached the drain: $drain"
  printf '%s\n' "$drain" | grep -F 'sample-route-call [key=sample-route-call]' >/dev/null \
    || fail "the drain section omitted the collapsed-identity divergence: $drain"
  printf '%s\n' "$drain" | grep -F "$id-decision-access [key=access]" >/dev/null \
    || fail "the drain section omitted the legacy-identity divergence: $drain"

  # It signals; it never closes. Both records must survive the report unchanged,
  # because closing a captain call wrongly removes it from review entirely.
  assert_grep "sample-route-call" "$home/data/backlog.md" "the report must not remove the captain-held task"
  tasks_in "$home" show sample-route-call --full | grep -E '^  held: yes' >/dev/null \
    || fail "the report released or closed the captain-held task"
  [ "$(grep -c '^resolved \[key=sample-route-call\]' "$home/state/$id.status")" = 1 ] \
    || fail "the report rewrote the status log"

  # And it names BOTH reconciliation directions. A status resolution is not proof
  # the captain ruled: one of the real cases dissolved because its premise was
  # false and another was a question of fact whose first reading was wrong, so
  # the only safe instruction is "reconcile with what actually happened".
  printf '%s\n' "$drain" | grep -F 'fm-captain-hold.sh answer' >/dev/null \
    || fail "the drain section does not say how to record the captain's answer: $drain"
  printf '%s\n' "$drain" | grep -F 're-open the status decision' >/dev/null \
    || fail "the drain section does not offer the re-open direction: $drain"
  pass "a status resolution over a still-open captain-held task is signalled, not closed"
}

# The false-signal boundary, driven by the shapes that are genuinely fine. A
# captain call whose deliverable IS the decision has no routed work item at all,
# and that is legitimate: routed work must never be part of the test. Nor may a
# verified `captain-held` transfer, a still-open status decision, an already
# answered call, or an ordinary task that merely had a keyed question answered.

test_legitimate_holds_produce_no_divergence_signal() {
  local home id out drain answer
  home=$(make_home divergence-no-false-signal)
  id=sample-systems-review
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"

  # (1) The decision IS the deliverable: held for the captain, nothing routed,
  # no status line anywhere naming it.
  run_captain "$home" hold sample-standalone-call \
    --title "Adopt the sample naming convention" --reason "captain call with no routed work" \
    --repo sample >/dev/null || fail "could not register the deliverable-is-the-decision call"
  # (2) The verified transfer: still open structurally, closed on the status side
  # by the captain-held verb command_complete writes.
  run_captain "$home" hold sample-transfer-call \
    --title "Choose the sample retention window" --reason "captain retention choice pending" \
    --repo sample >/dev/null || fail "could not register the transferred call"
  # (4) An already answered call whose status line reads resolved.
  run_captain "$home" hold sample-answered-call \
    --title "Choose the sample export format" --reason "captain export choice pending" \
    --repo sample >/dev/null || fail "could not register the answered call"
  answer="$home/answer.txt"
  printf 'Export as CSV.\n' > "$answer"
  run_captain "$home" answer sample-answered-call --decision-file "$answer" >/dev/null \
    || fail "could not record the captain answer fixture"
  # (5) An ordinary in-flight work item that is not held for the captain.
  tasks_in "$home" add sample-plain-work "Ordinary sample work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the ordinary work fixture"

  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-transfer-call]: choose the retention window
captain-held [key=sample-transfer-call]: tracked by sample-transfer-call
needs-decision [key=sample-open-call]: still open on both sides
needs-decision [key=sample-answered-call]: choose the export format
resolved [key=sample-answered-call]: answered: CSV
needs-decision [key=sample-plain-work]: worker question about the sample fixture
resolved [key=sample-plain-work]: answered: go ahead
EOF
  # (3) A still-open status decision whose structured twin is also still open.
  run_captain "$home" hold sample-open-call \
    --title "Choose the sample refresh cadence" --reason "captain cadence choice pending" \
    --repo sample >/dev/null || fail "could not register the still-open call"

  out=$(run_captain "$home" diverged) || fail "diverged failed on the legitimate shapes"
  [ -z "$out" ] || fail "legitimate captain holds produced a false divergence signal: $out"

  drain=$(run_drain "$home") || fail "the drain failed on the legitimate shapes"
  if printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null; then
    fail "the drain printed a divergence section with nothing diverging: $drain"
  fi
  printf '%s\n' "$drain" | grep -F 'sample-open-call' >/dev/null \
    || fail "setup error: the still-open decision should still reach OPEN DECISIONS: $drain"
  pass "a captain call with no routed work, a verified transfer, an open decision, and an answered call all stay silent"
}

# The originating work item is itself the captain call, which is what the policy
# prefers ("hold the work item the question gates"). Cleanup of that finished
# work must never be the act that closes the captain's own row: the deliverable
# is recorded on the still-held row, the call keeps reading as open on the
# board, and only a recorded answer closes it. An ordinary finished task in the
# same home must still close exactly as before, and discard authority covers
# unlanded work, never the captain's question.

run_case test_secondmate_hold_stays_in_authoritative_home
run_case test_secondmate_home_publishes_holds_and_answers
run_case test_secondmate_reconcile_publishes_before_request_retirement
run_case test_bound_channel_answers_close_at_answer_time
run_case test_reconcile_never_closes_through_the_keyed_answer_intake
run_case test_normal_answers_retire_pending_reconcile_requests
run_case test_reconcile_closes_with_evidence_or_keeps_the_call_open
run_case test_reconcile_outcomes_retry_partial_failures_once
run_case test_unbound_source_closes_no_hold
run_case test_legacy_identities_keep_working
run_case test_board_answer_reaches_the_keyed_answer_intake
run_case test_chat_channel_feeds_the_same_keyed_answer_intake
run_case test_origin_slug_validation_precedes_path_construction
run_case test_status_resolution_over_an_open_hold_is_signalled
run_case test_legitimate_holds_produce_no_divergence_signal
