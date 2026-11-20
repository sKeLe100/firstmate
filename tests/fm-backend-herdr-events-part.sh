#!/usr/bin/env bash
# tests/fm-backend-herdr-events-part.sh - fake-herdr-CLI cases for fm-backend.sh
# dispatch wiring, workspace lifecycle and default-tab pruning safety, and
# native event push. Sourced by tests/fm-backend-herdr.test.sh after its fakes
# and helpers, which also runs every case.

# --- fm-backend.sh dispatch wiring -------------------------------------------

test_dispatch_routes_herdr_backend() {
  fm_backend_validate herdr 2>/dev/null || fail "fm_backend_validate should accept herdr (P2 adds it to FM_BACKEND_KNOWN)"
  pass "fm_backend_validate: herdr is a known backend (P2)"
}

test_dispatch_busy_state_unknown_for_tmux() {
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  [ "$(fm_backend_busy_state tmux 'sess:win')" = unknown ] \
    || fail "fm_backend_busy_state should report unknown for tmux (no native agent-state primitive; watcher falls back to regex)"
  pass "fm_backend_busy_state: tmux (no native primitive) always reports unknown, preserving the P1 regex-only path"
}

test_dispatch_composer_state_routes_by_backend() {
  # fm_backend_composer_state (the generic per-backend composer/pending-input
  # classifier the away-mode daemon dispatches through - bin/fm-supervise-daemon.sh's
  # pane_input_pending) must route to each backend's OWN named classifier with
  # the target passed through unchanged - every backend has one now, all thin
  # wrappers over the shared fm_composer_classify_screen - and report unknown
  # for an unrecognized backend name.
  # Sourced-guards are pre-set so fm_backend_source no-ops and these stubs are
  # never clobbered by the real per-backend files trying (and failing) a live call.
  (
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    _FM_BACKEND_TMUX_SOURCED=1
    _FM_BACKEND_HERDR_SOURCED=1
    _FM_BACKEND_ORCA_SOURCED=1
    _FM_BACKEND_ZELLIJ_SOURCED=1
    fm_tmux_composer_state() { [ "$1" = "sess:win" ] || fail "tmux composer_state got wrong target: $1"; printf 'pending'; }
    fm_backend_herdr_composer_state() { [ "$1" = "default:w1:p2" ] || fail "herdr composer_state got wrong target: $1"; printf 'empty'; }
    fm_backend_orca_composer_state() { [ "$1" = "term-1" ] || fail "orca composer_state got wrong target: $1"; printf 'empty'; }
    fm_backend_zellij_composer_state() { [ "$1" = "sess:7" ] || fail "zellij composer_state got wrong target: $1"; printf 'empty'; }
    [ "$(fm_backend_composer_state tmux sess:win)" = pending ] || fail "composer_state did not dispatch to the tmux classifier"
    [ "$(fm_backend_composer_state herdr default:w1:p2)" = empty ] || fail "composer_state did not dispatch to the herdr classifier"
    [ "$(fm_backend_composer_state orca term-1)" = empty ] || fail "composer_state did not dispatch to the orca classifier"
    [ "$(fm_backend_composer_state zellij sess:7)" = empty ] || fail "composer_state did not dispatch to the zellij classifier"
    [ "$(fm_backend_composer_state bogus x)" = unknown ] || fail "composer_state should report unknown for an unrecognized backend"
  ) || fail "composer_state dispatch subshell failed"
  pass "fm_backend_composer_state dispatches every backend to its named thin classifier, unknown for unrecognized backends"
}

test_scripts_route_explicit_target_through_meta_backend() {
  local dir state log resp fb neutral out
  dir="$TMP_ROOT/script-explicit-target"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  neutral="$dir/neutral-root"; mkdir -p "$neutral"
  fm_write_meta "$state/herdr-stale.meta" "window=default:w1:p2" "backend=herdr"
  touch "$state/.last-watcher-beat"
  printf 'captured herdr pane\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf 'tmux should not be used for a metadata-matched herdr target\n' >&2
exit 42
SH
  chmod +x "$fb/tmux"

  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    "$ROOT/bin/fm-peek.sh" default:w1:p2 5 2>/dev/null )
  [ "$out" = "captured herdr pane" ] || fail "fm-peek did not capture through herdr for an explicit metadata-matched target, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2' \
    "fm-peek did not route the explicit stale target through herdr capture"

  : > "$log"
  PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    "$ROOT/bin/fm-send.sh" default:w1:p2 --key Escape >/dev/null 2>&1
  expect_code 0 $? "fm-send --key should route an explicit metadata-matched target through herdr"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''escape' \
    "fm-send did not route the explicit stale target through herdr send-key"

  pass "fm-peek/fm-send: explicit stale targets matching metadata use the recorded backend"
}

# --- workspace lifecycle: reuse, no orphans, default-tab pruning -------------

test_workspace_ensure_prunes_default_tab() {
  local dir log state fb raw container seeded wsid ids pane tabcount
  dir="$TMP_ROOT/prune-default"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
    || fail "container_ensure failed against the stateful fake"
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  wsid=${container#*:}
  [ -n "$seeded" ] || fail "container_ensure should report the seeded default tab id for a freshly created workspace, got raw='$raw'"
  # herdr seeds a fresh workspace with one auto-created default tab (label "1")
  # and closing a workspace's LAST tab deletes the whole workspace on real
  # herdr, so the adapter must not prune it until a real task tab exists
  # alongside it - verify it is still present right after container_ensure.
  tabcount=$(jq -r --arg w "$wsid" '[.tabs[]|select(.workspace_id==$w)]|length' "$state")
  [ "$tabcount" = 1 ] || fail "expected the untouched default tab to remain after container_ensure alone, got $tabcount tab(s): $(jq -c '.tabs' "$state")"
  ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-prunetest" "$seeded" ) \
    || fail "create_task failed against the stateful fake"
  read -r _ pane <<EOF
$ids
EOF
  [ -n "$pane" ] || fail "create_task returned no pane id"
  # Once the real task tab exists, create_task must prune the SEEDED default
  # tab id container_ensure captured, so only the real task tab remains.
  tabcount=$(jq -r --arg w "$wsid" '[.tabs[]|select(.workspace_id==$w)]|length' "$state")
  [ "$tabcount" = 1 ] || fail "the auto-created default tab should be pruned once a real task tab exists, $tabcount tab(s) remain: $(jq -c '.tabs' "$state")"
  jq -r --arg w "$wsid" '[.tabs[]|select(.workspace_id==$w)][0].label' "$state" | grep -qx 'fm-prunetest' \
    || fail "the surviving tab should be the real task tab, not the default: $(jq -c '.tabs' "$state")"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close' "create_task did not close the default tab's pane"
  pass "fm_backend_herdr_create_task: prunes exactly the seeded default tab container_ensure identified, once the first real task tab exists"
}

test_repeated_cycles_reuse_one_workspace_no_orphans() {
  local dir log state fb i raw container seeded wsid ids pane first_ws="" wscount total tabcount created
  dir="$TMP_ROOT/cycles"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  for i in 1 2 3; do
    raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
      || fail "cycle $i: container_ensure failed"
    container=${raw%%$'\t'*}
    seeded=${raw#*$'\t'}
    case "$container" in fmtest:w*) : ;; *) fail "cycle $i: unexpected container '$container'" ;; esac
    wsid=${container#*:}
    if [ -z "$first_ws" ]; then
      first_ws=$wsid
      [ -n "$seeded" ] || fail "cycle $i: the first cycle must create a fresh workspace and report its seeded default tab id"
    else
      [ "$wsid" = "$first_ws" ] || fail "cycle $i: workspace not reused ('$wsid' != '$first_ws')"
      [ -z "$seeded" ] || fail "cycle $i: a REUSED (adopted) workspace must never report a seeded default tab id, got '$seeded'"
    fi
    ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-cycle$i" "$seeded" ) \
      || fail "cycle $i: create_task failed"
    read -r _ pane <<EOF
$ids
EOF
    [ -n "$pane" ] || fail "cycle $i: create_task returned no pane id"
    PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
      bash -c '
        . "$0/bin/backends/herdr.sh"
        fm_backend_herdr_presentation_session_lock_path() { printf "/tmp/fm-herdr-cycle-test-lock"; }
        fm_lock_try_acquire() { return 0; }
        fm_lock_release() { return 0; }
        fm_backend_herdr_kill "$1"
      ' "$ROOT" "fmtest:$pane" \
      || fail "cycle $i: kill failed"
  done
  # exactly one firstmate workspace survives three spawn/teardown cycles
  wscount=$(jq -r '[.workspaces[]|select(.label=="firstmate")]|length' "$state")
  [ "$wscount" = 1 ] || fail "expected exactly 1 firstmate workspace after 3 cycles, got $wscount: $(jq -c '.workspaces' "$state")"
  # and no orphaned workspaces of any label
  total=$(jq -r '.workspaces|length' "$state")
  [ "$total" = 1 ] || fail "expected no orphaned workspaces after 3 cycles, got $total total: $(jq -c '.workspaces' "$state")"
  # zero tabs remain: every fm- task tab torn down AND the default tab pruned
  tabcount=$(jq -r '.tabs|length' "$state")
  [ "$tabcount" = 0 ] || fail "expected 0 tabs after teardown (default tab pruned, task tabs killed), got $tabcount: $(jq -c '.tabs' "$state")"
  # the workspace was minted once and reused thereafter, never re-created
  created=$(grep -c $'\x1f''workspace'$'\x1f''create' "$log")
  [ "$created" = 1 ] || fail "workspace create should run exactly once across 3 cycles (reuse, not re-mint), ran $created times"
  pass "herdr repeated spawn/teardown: one persistent firstmate workspace reused, zero orphans, default tab pruned, create ran once"
}

# --- created-vs-adopted default-tab-prune safety (2026-07-02 self-kill fix) -
#
# Root cause and fix are documented at
# fm_backend_herdr_workspace_prune_seeded_default_tab in bin/backends/herdr.sh
# and docs/herdr-backend.md's "Default-tab prune" section. These three tests
# cover the acceptance bar directly: an ADOPTED workspace's tab is never a
# prune candidate (regardless of label or count), a freshly CREATED
# workspace's seeded default tab IS pruned (already covered above by
# test_workspace_ensure_prunes_default_tab and
# test_repeated_cycles_reuse_one_workspace_no_orphans), and the exact
# label-collision startup-workspace shape that caused the real incident
# leaves the live tab alone.

test_adopted_workspace_never_prunes_default_tab() {
  # An ADOPTED workspace (fm_backend_herdr_workspace_find matched a
  # pre-existing workspace by label) must never have any tab pruned by
  # create_task, regardless of that tab's label or count - the created-vs-
  # adopted gate is structural (an empty seeded_tab_id), never re-derived
  # from label patterns at create_task time.
  local dir log state fb raw container seeded ids pane
  dir="$TMP_ROOT/adopt-no-prune"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  # Pre-seed a workspace that ALREADY exists before this spawn runs (as if a
  # previous session created it), with a single tab labeled "1" - the same
  # shape herdr's own auto-seeded default tab has, but this run's own
  # container_ensure never ran a `workspace create` call to produce it.
  jq -n '{next:2,workspaces:[{workspace_id:"w1",label:"firstmate"}],tabs:[{tab_id:"w1:t1",label:"1",workspace_id:"w1",pane_id:"w1:p1"}],agent_status:{}}' > "$state"
  raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
    || fail "container_ensure failed against the stateful fake"
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  [ "$container" = "fmtest:w1" ] || fail "container_ensure should have ADOPTED the pre-existing workspace w1, got '$container'"
  [ -z "$seeded" ] || fail "an ADOPTED workspace must report an EMPTY seeded default tab id, got '$seeded'"
  assert_not_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create' "container_ensure must not create a new workspace when one already exists to adopt"

  ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-adopttest" "$seeded" ) \
    || fail "create_task failed against the stateful fake"
  read -r _ pane <<EOF
$ids
EOF
  [ -n "$pane" ] || fail "create_task returned no pane id"

  # The pre-existing tab (and its pane) must be COMPLETELY untouched.
  jq -e '.tabs[] | select(.tab_id == "w1:t1")' "$state" >/dev/null \
    || fail "the pre-existing (adopted) tab w1:t1 was removed - an adopted workspace's tab must never be pruned"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w1:p1' \
    "create_task must never close a tab belonging to an ADOPTED workspace, no matter its label or count"
  pass "fm_backend_herdr_create_task: an ADOPTED workspace's pre-existing tab is never pruned (the created-vs-adopted gate)"
}

test_label_collision_startup_workspace_leaves_live_tab_alone() {
  # The exact live-fire incident shape (2026-07-02): a captain launches herdr
  # directly inside a directory named "firstmate", so herdr auto-derives that
  # workspace's DISPLAYED label from the cwd basename - "firstmate" - byte-
  # identical to the primary firstmate home's own derived label, with no
  # --label ever passed and no firstmate involvement at all. That workspace's
  # single auto-created tab (label "1") holds the captain's own live agent.
  # The very next crewmate spawn must adopt-and-leave-alone, never prune.
  local dir log state fb raw container seeded ids pane
  dir="$TMP_ROOT/label-collision"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  # Mimic a bare `herdr workspace create --cwd <dir-named-firstmate>` (no
  # --label): the resulting workspace's label is the cwd basename, and its
  # one auto-created tab is still labeled "1" - indistinguishable, by label
  # alone, from firstmate's own freshly-seeded default tab. Its pane hosts a
  # live agent (agent_status=working), exactly like the captain's own pane.
  jq -n '{next:2,workspaces:[{workspace_id:"w1",label:"firstmate"}],tabs:[{tab_id:"w1:t1",label:"1",workspace_id:"w1",pane_id:"w1:p1"}],agent_status:{"w1:p1":"working"}}' > "$state"
  raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
    || fail "container_ensure failed against the stateful fake"
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  [ "$container" = "fmtest:w1" ] || fail "container_ensure should adopt the captain's coincidentally-labeled workspace, got '$container'"
  [ -z "$seeded" ] || fail "the coincidentally-labeled workspace was ADOPTED, not created, so seeded default tab id must be empty, got '$seeded'"

  ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-collisiontest" "$seeded" ) \
    || fail "create_task failed against the stateful fake"
  read -r _ pane <<EOF
$ids
EOF
  [ -n "$pane" ] || fail "create_task returned no pane id"

  jq -e '.tabs[] | select(.tab_id == "w1:t1")' "$state" >/dev/null \
    || fail "REGRESSION: the captain's live tab was closed - this is the exact 2026-07-02 self-kill incident"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w1:p1' \
    "REGRESSION: create_task closed the captain's live pane in the label-collision scenario"
  pass "fm_backend_herdr_create_task: the label-collision startup-workspace scenario (2026-07-02 incident) leaves the captain's live tab untouched"
}

test_prune_refuses_a_working_agent_pane_defense_in_depth() {
  # Defense in depth (not the primary safety mechanism): even for a
  # freshly-created workspace with a genuine non-empty seeded default tab id,
  # if that specific pane's agent reports "working" by the time create_task
  # runs, the prune must refuse rather than close a live agent's pane.
  local dir log state fb raw container seeded seeded_pane ids pane
  dir="$TMP_ROOT/prune-busy-defense"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
    || fail "container_ensure failed against the stateful fake"
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  [ -n "$seeded" ] || fail "expected a freshly created workspace to report a seeded default tab id"
  # Mark the seeded default tab's pane as hosting a working agent (simulates
  # some other path landing a live agent there between creation and prune).
  seeded_pane=$(jq -r --arg t "$seeded" '.tabs[] | select(.tab_id == $t) | .pane_id' "$state")
  [ -n "$seeded_pane" ] || fail "could not resolve the seeded default tab's pane id from state"
  fake_herdr_set_agent_status "$state" "$seeded_pane" working

  ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-busytest" "$seeded" ) \
    || fail "create_task failed against the stateful fake"
  read -r _ pane <<EOF
$ids
EOF
  [ -n "$pane" ] || fail "create_task returned no pane id"

  jq -e --arg t "$seeded" '.tabs[] | select(.tab_id == $t)' "$state" >/dev/null \
    || fail "the seeded default tab was closed despite its pane reporting a working agent (defense-in-depth failed)"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f'"$seeded_pane" \
    "create_task must refuse to close a seeded default tab whose pane hosts a working agent"
  pass "fm_backend_herdr_workspace_prune_seeded_default_tab: refuses to close the seeded default tab when its pane reports a working agent (defense in depth)"
}

# --- native event push: normalize / policy-routing / dedupe / wait ----------
#
# These exercise the herdr subscriber (fm_backend_herdr_wait_transition and its
# helpers) with a FAKE socket reader and fake herdr CLI, so the policy routing,
# per-pane dedupe marker, reconnect level-reconcile, and fail-closed return
# codes are asserted without a real herdr server. The isolated real-herdr smoke
# that drives a live idle->blocked transition lives in
# tests/fm-backend-herdr-eventwait-smoke.test.sh.

# make_herdr_eventfake: a herdr stub answering exactly the calls the event path
# makes - `session list --json` (echoes one session, name FM_FAKE_SESSION_NAME,
# socket FM_FAKE_SOCKET), `status --json`, and `agent get <pane>` (per-pane
# status read from $FM_FAKE_AGENT_DIR/<key>.status, else agent_not_found).
make_herdr_eventfake() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:-/dev/null}"
{ printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$LOG"
cmd=${1:-}; sub=${2:-}
case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.3","protocol":16},"server":{"running":true}}\n' ;;
  "session list")
    printf '{"sessions":[{"name":"%s","running":true,"default":false,"socket_path":"%s"}]}\n' \
      "${FM_FAKE_SESSION_NAME:-default}" "${FM_FAKE_SOCKET:-/tmp/fm-fake.sock}" ;;
  "agent get")
    if [ -n "${FM_FAKE_READER_READY_FILE:-}" ] && [ ! -e "$FM_FAKE_READER_READY_FILE" ]; then
      exit 9
    fi
    pane=${3:-}
    key=$(printf '%s' "$pane" | tr ':/.' '___')
    f="${FM_FAKE_AGENT_DIR:-/tmp}/$key.status"
    if [ -f "$f" ]; then
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$(cat "$f")"
    else
      printf '{"error":{"code":"agent_not_found"}}\n' >&2
      exit 1
    fi ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# make_fake_reader: a stand-in for bin/backends/herdr-eventwait.py. It ignores
# the socket, streams the TAB-separated lines in $FM_FAKE_READER_LINES to stdout
# (one projected event per line: pane_id\tworkspace_id\tagent_status\tagent),
# then exits $FM_FAKE_READER_EXIT (default 0). A non-zero exit with no lines
# models a connect/subscribe failure.
make_fake_reader() {  # <dir> -> echoes reader path
  local dir=$1 path="$1/fake-reader.sh"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
# argv: <sock> <timeout> <pane...> - ignored; behavior is env-driven.
if [ -n "${FM_FAKE_READER_READY_FILE:-}" ]; then
  : > "$FM_FAKE_READER_READY_FILE"
fi
printf '%s\n' "${FM_FAKE_READER_ACK:-@subscribed}"
if [ -n "${FM_FAKE_READER_LINES:-}" ] && [ -f "$FM_FAKE_READER_LINES" ]; then
  cat "$FM_FAKE_READER_LINES"
fi
exit "${FM_FAKE_READER_EXIT:-0}"
SH
  chmod +x "$path"
  printf '%s\n' "$path"
}

set_fake_agent() {  # <agent-dir> <window-or-pane> <status>
  local dir=$1 target=$2 status=$3 key
  key=$(printf '%s' "$target" | tr ':/.' '___')
  mkdir -p "$dir"
  printf '%s' "$status" > "$dir/$key.status"
}

test_normalize_event_leaves_from_empty() {
  local rec
  rec=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_normalize_event wG:pQ wG blocked claude' "$ROOT")
  [ "$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_pane_id "$1"' "$ROOT" "$rec")" = "wG:pQ" ] \
    || fail "normalize_event pane_id wrong: $rec"
  [ "$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_from_status "$1"' "$ROOT" "$rec")" = "" ] \
    || fail "normalize_event should leave from_status empty (herdr carries no previous status): $rec"
  [ "$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_to_status "$1"' "$ROOT" "$rec")" = "blocked" ] \
    || fail "normalize_event to_status wrong: $rec"
  pass "fm_backend_herdr_normalize_event routes through the shared record with an empty from_status"
}

test_escalation_marker_keys_like_watcher() {
  local m
  m=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_escalation_marker /st default:wG:pQ' "$ROOT")
  [ "$m" = "/st/.herdr-escalated-default_wG_pQ" ] \
    || fail "escalation marker key must match the watcher's tr ':/.' '___' scheme, got '$m'"
  pass "fm_backend_herdr_escalation_marker keys the dedupe marker exactly like the watcher's .stale-<key>"
}

test_apply_transition_blocked_requires_commit_to_dedupe() {
  local dir state rec out rc marker
  dir="$TMP_ROOT/apply-blocked"; state="$dir/state"; mkdir -p "$state"
  rec=$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_record wG:pQ wG "" blocked claude' "$ROOT")
  marker="$state/.herdr-escalated-default_wG_pQ"
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$rec"); rc=$?
  [ "$rc" = 0 ] || fail "a fresh blocked edge must return 0 (actionable), got $rc"
  case "$out" in *blocked*) : ;; *) fail "apply_transition should print the record on a fresh actionable edge, got '$out'" ;; esac
  [ ! -e "$marker" ] || fail "detecting a blocked edge must not commit its marker before durable handling"
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_commit_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$rec"
  [ -e "$marker" ] || fail "commit_transition must set the marker after the caller handles the edge"
  # Second identical blocked edge (marker present) must NOT re-fire.
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$rec"); rc=$?
  [ "$rc" = 1 ] || fail "an already-marked blocked pane must return 1 (deduped), got $rc"
  [ -z "$out" ] || fail "an already-marked blocked pane must print nothing, got '$out'"
  pass "fm_backend_herdr_apply_transition: blocked dedupe starts only after explicit commit"
}

test_apply_transition_working_clears_marker() {
  local dir state blocked working marker rc
  dir="$TMP_ROOT/apply-working"; state="$dir/state"; mkdir -p "$state"
  marker="$state/.herdr-escalated-default_wG_pQ"
  blocked=$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_record wG:pQ wG "" blocked claude' "$ROOT")
  working=$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_record wG:pQ wG "" working claude' "$ROOT")
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_commit_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$blocked"
  [ -e "$marker" ] || fail "setup: committed blocked edge should have set the marker"
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$working"; rc=$?
  [ "$rc" = 1 ] || fail "a working (absorb) edge must return 1 (no wake), got $rc"
  [ ! -e "$marker" ] || fail "a working edge must CLEAR the escalation marker so a later re-block re-fires"
  # A re-block after the clear must fire again.
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$blocked" >/dev/null; rc=$?
  [ "$rc" = 0 ] || fail "a re-block after a working clear must re-fire (return 0), got $rc"
  pass "fm_backend_herdr_apply_transition: a working edge clears the marker so the next ->blocked re-escalates"
}

test_clear_transition_removes_task_marker() {
  local dir state marker
  dir="$TMP_ROOT/clear-transition"; state="$dir/state"; mkdir -p "$state"
  marker="$state/.herdr-escalated-default_wG_pQ"
  : > "$marker"
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_clear_transition "$1" "$2"' "$ROOT" "$state" default:wG:pQ
  [ ! -e "$marker" ] || fail "clear_transition must remove the marker owned by a torn-down pane"
  pass "fm_backend_herdr_clear_transition removes task-owned dedupe state"
}

test_apply_transition_defer_and_fallback_are_noops() {
  local dir state marker rc s
  dir="$TMP_ROOT/apply-defer"; state="$dir/state"; mkdir -p "$state"
  marker="$state/.herdr-escalated-default_wG_pQ"
  for s in idle "done" unknown ""; do
    local rec
    rec=$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_record wG:pQ wG "" "$1" claude' "$ROOT" "$s")
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$rec"; rc=$?
    [ "$rc" = 1 ] || fail "defer/fallback status '$s' must return 1 (no fast action), got $rc"
    [ ! -e "$marker" ] || fail "defer/fallback status '$s' must not touch the escalation marker"
  done
  pass "fm_backend_herdr_apply_transition: idle/done (defer) and unknown/empty (fallback) take no fast action"
}

test_wait_transition_no_panes_returns_2() {
  local rc
  bash -c '. "$0/bin/backends/herdr.sh"; FM_BACKEND_HERDR_EVENTS_FORCE=1 fm_backend_herdr_wait_transition default 1 /tmp/st' "$ROOT"; rc=$?
  [ "$rc" = 2 ] || fail "wait_transition with no pane windows must return 2 (fall back to sleep), got $rc"
  pass "fm_backend_herdr_wait_transition: a home with no herdr panes falls back to polling (rc 2)"
}

test_wait_transition_not_capable_returns_2() {
  local dir state fb rc
  dir="$TMP_ROOT/wt-incapable"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_herdr_eventfake "$dir")
  rc=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=0 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 2 ] || fail "wait_transition must return 2 when events are below capability (fail closed to poll), got $rc"
  pass "fm_backend_herdr_wait_transition: below-capability protocol/schema falls back to polling (rc 2)"
}

test_wait_transition_reconcile_blocked_returns_record() {
  local dir state agent temp fb reader lines out rc marker
  dir="$TMP_ROOT/wt-reconcile"; state="$dir/state"; agent="$dir/agents"; temp="$dir/temp"; mkdir -p "$state" "$agent" "$temp"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" blocked
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"
  marker="$state/.herdr-escalated-sess_wG_pQ"
  out=$(PATH="$fb:$PATH" TMPDIR="$temp" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ' "$ROOT" "$state"); rc=$?
  [ "$rc" = 0 ] || fail "reconcile of an already-blocked pane must return 0, got $rc"
  case "$out" in *blocked*) : ;; *) fail "reconcile must print the blocked record, got '$out'" ;; esac
  [ ! -e "$marker" ] || fail "reconcile must not mark a blocked pane before the caller durably handles it"
  [ -z "$(find "$temp" -mindepth 1 -print -quit)" ] || fail "actionable reconciliation must remove its private FIFO directory"
  pass "fm_backend_herdr_wait_transition: reconnect level-reconcile returns an uncommitted blocked pane"
}

test_wait_transition_subscribes_before_reconcile() {
  local dir state agent fb reader lines ready rc
  dir="$TMP_ROOT/wt-subscribe-first"; state="$dir/state"; agent="$dir/agents"; mkdir -p "$state" "$agent"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; ready="$dir/subscribed"; : > "$lines"
  rc=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" FM_FAKE_READER_READY_FILE="$ready" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 1 ] || fail "subscription must be acknowledged before reconciliation begins, got $rc"
  pass "fm_backend_herdr_wait_transition: subscribes before reconnect level-reconcile"
}

test_wait_transition_reconcile_dedupes_when_marked() {
  local dir state agent fb rc
  dir="$TMP_ROOT/wt-reconcile-dedupe"; state="$dir/state"; agent="$dir/agents"; mkdir -p "$state" "$agent"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" blocked
  # Pre-mark: this blocked was already escalated.
  : > "$state/.herdr-escalated-sess_wG_pQ"
  # No stream events, reader exits 0 -> a clean timeout (rc 1), NOT a re-fire.
  local reader lines
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"
  rc=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 1 ] || fail "an already-marked blocked pane must not re-fire on reconcile (expect clean timeout rc 1), got $rc"
  pass "fm_backend_herdr_wait_transition: a still-blocked, already-escalated pane is not re-delivered on reconnect"
}

test_wait_transition_stream_blocked_returns_record() {
  local dir state agent fb reader lines out rc marker
  dir="$TMP_ROOT/wt-stream-blocked"; state="$dir/state"; agent="$dir/agents"; mkdir -p "$state" "$agent"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle   # reconcile sees idle -> proceeds to stream
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"
  printf 'wG:pQ\t\tblocked\tclaude\n' > "$lines"
  marker="$state/.herdr-escalated-sess_wG_pQ"
  out=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 2 "$1" sess:wG:pQ' "$ROOT" "$state"); rc=$?
  [ "$rc" = 0 ] || fail "a streamed blocked edge must return 0, got $rc"
  case "$out" in *blocked*) : ;; *) fail "a streamed blocked edge must print the record, got '$out'" ;; esac
  [ ! -e "$marker" ] || fail "a streamed blocked edge must remain uncommitted until durable handling"
  pass "fm_backend_herdr_wait_transition: a streamed ->blocked edge returns the record sub-poll"
}

test_wait_transition_stream_absorb_clears_then_timeout() {
  local dir state agent fb reader lines rc marker
  dir="$TMP_ROOT/wt-stream-absorb"; state="$dir/state"; agent="$dir/agents"; mkdir -p "$state" "$agent"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  : > "$state/.herdr-escalated-sess_wG_pQ"   # previously escalated
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"
  marker="$state/.herdr-escalated-sess_wG_pQ"
  # Stream a working edge (absorb) then an idle edge (defer). Neither is a fresh
  # actionable edge, so the wait ends as a clean timeout (rc 1) and the marker
  # is cleared by the working edge.
  printf 'wG:pQ\t\tworking\tclaude\nwG:pQ\t\tidle\tclaude\n' > "$lines"
  rc=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 2 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 1 ] || fail "a stream of only working/idle edges must end as a clean timeout (rc 1), got $rc"
  [ ! -e "$marker" ] || fail "a streamed working edge must clear the escalation marker"
  pass "fm_backend_herdr_wait_transition: streamed working clears the marker, idle/done are deferred (clean timeout)"
}

test_wait_transition_reader_failure_returns_2() {
  local dir state agent temp fb reader lines rc
  dir="$TMP_ROOT/wt-reader-fail"; state="$dir/state"; agent="$dir/agents"; temp="$dir/temp"; mkdir -p "$state" "$agent" "$temp"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"
  rc=$(PATH="$fb:$PATH" TMPDIR="$temp" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" FM_FAKE_READER_EXIT=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 2 ] || fail "a reader connect/subscribe failure must return 2 (fall back to poll), got $rc"
  [ -z "$(find "$temp" -mindepth 1 -print -quit)" ] || fail "reader failure must remove its private FIFO directory"
  pass "fm_backend_herdr_wait_transition: a reader/subscribe failure falls back to polling (rc 2)"
}

test_wait_transition_bad_ack_returns_2_and_cleans_up() {
  local dir state agent temp fb reader lines result rc fd_open
  dir="$TMP_ROOT/wt-bad-ack"; state="$dir/state"; agent="$dir/agents"; temp="$dir/temp"; mkdir -p "$state" "$agent" "$temp"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"
  result=$(PATH="$fb:$PATH" TMPDIR="$temp" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" FM_FAKE_READER_ACK=invalid \
    /bin/bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; rc=$?; [ -e /dev/fd/9 ] && fd_open=yes || fd_open=no; printf "%s %s\n" "$rc" "$fd_open"' "$ROOT" "$state")
  rc=${result%% *}; fd_open=${result#* }
  [ "$rc" = 2 ] || fail "an invalid subscription acknowledgement must return 2, got $rc"
  [ "$fd_open" = no ] || fail "an invalid subscription acknowledgement must close fixed fd 9"
  [ -z "$(find "$temp" -mindepth 1 -print -quit)" ] || fail "an invalid subscription acknowledgement must remove its private FIFO directory"
  pass "fm_backend_herdr_wait_transition: Bash 3.2-safe bad-ack path closes fd 9 and removes its FIFO"
}

test_wait_transition_clean_timeout_returns_1() {
  local dir state agent temp fb reader lines result rc fd_open
  dir="$TMP_ROOT/wt-timeout"; state="$dir/state"; agent="$dir/agents"; temp="$dir/temp"; mkdir -p "$state" "$agent" "$temp"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"   # no events, reader exits 0
  result=$(PATH="$fb:$PATH" TMPDIR="$temp" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    /bin/bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; rc=$?; [ -e /dev/fd/9 ] && fd_open=yes || fd_open=no; printf "%s %s\n" "$rc" "$fd_open"' "$ROOT" "$state")
  rc=${result%% *}; fd_open=${result#* }
  [ "$rc" = 1 ] || fail "a clean full-budget wait with no actionable edge must return 1, got $rc"
  [ "$fd_open" = no ] || fail "a clean timeout must close fixed fd 9"
  [ -z "$(find "$temp" -mindepth 1 -print -quit)" ] || fail "a clean timeout must remove its private FIFO directory"
  pass "fm_backend_herdr_wait_transition: stock macOS Bash clean timeout closes fd 9 and returns 1"
}

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
