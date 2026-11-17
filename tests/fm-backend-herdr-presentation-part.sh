#!/usr/bin/env bash
# tests/fm-backend-herdr-presentation-part.sh - fake-herdr-CLI cases for the
# default-on disposable presentation projection and the emptying-close
# focus-safe removal. Sourced by tests/fm-backend-herdr.test.sh after its fakes
# and helpers, which also runs every case.

# --- default-on disposable presentation projection --------------------------

# make_release_fakebin: a `herdr` stub whose only job is `status --json`, so the
# presentation version floor can be exercised against scripted client and
# selected-session server releases with no herdr installed at all. An empty
# protocol or version omits that field; the literal client value "unreadable"
# makes the whole call fail, and a server-running value other than true or false
# omits that state.
make_release_fakebin() {  # <dir> <client-protocol> <client-version> [<server-running> <server-protocol> <server-version>] -> echoes fakebin dir
  local dir=$1 protocol=$2 version=$3 server_running=${4:-false} server_protocol=${5:-} server_version=${6:-}
  local fb="$1/release-fakebin" fields="" server_fields=""
  mkdir -p "$fb"
  if [ -n "$version" ]; then
    fields="\"version\":\"$version\""
  fi
  if [ -n "$protocol" ]; then
    [ -n "$fields" ] && fields="$fields,"
    fields="$fields\"protocol\":$protocol"
  fi
  case "$server_running" in
    true|false) server_fields="\"running\":$server_running" ;;
  esac
  if [ -n "$server_version" ]; then
    [ -n "$server_fields" ] && server_fields="$server_fields,"
    server_fields="$server_fields\"version\":\"$server_version\""
  fi
  if [ -n "$server_protocol" ]; then
    [ -n "$server_fields" ] && server_fields="$server_fields,"
    server_fields="$server_fields\"protocol\":$server_protocol"
  fi
  cat > "$fb/herdr" <<SH
#!/usr/bin/env bash
set -u
[ "\${1:-}" = status ] || exit 3
SH
  if [ "$protocol" = unreadable ] || [ "$version" = unreadable ]; then
    printf 'exit 4\n' >> "$fb/herdr"
  else
    printf 'printf %s\n' "'{\"client\":{$fields},\"server\":{$server_fields}}\\n'" >> "$fb/herdr"
  fi
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# fm_backend_herdr_presentation_enabled is the one gate bin/fm-spawn.sh consults
# before projecting a crewmate or scout, so these cases pin the default-on
# contract, its explicit opt-out, its explicit opt-in, and the version floor
# that decides the unconfigured default at that interface.
presentation_enabled_verdict() {  # <config-dir> <fakebin> [state-dir] [session] -> "on"/"off"
  HERDR_SESSION="${4:-}" PATH="$2:$PATH" bash -c '
    . "$0/bin/backends/herdr.sh"
    if fm_backend_herdr_presentation_enabled "$1" "$2"; then printf "on\n"; else printf "off\n"; fi
  ' "$ROOT" "$1" "${3:-}"
}

# The exact release identities measured against the real macOS aarch64 release
# binaries on 2026-08-05 and recorded in docs/verification/runtime-backends.md.
AT_FLOOR_PROTOCOL=19
AT_FLOOR_VERSION=0.8.0
BELOW_FLOOR_PROTOCOL=17
BELOW_FLOOR_VERSION=0.7.5

test_presentation_defaults_on_at_or_above_the_floor() {
  local dir config fb verdict stderr
  dir="$TMP_ROOT/presentation-default-on"; config="$dir/config"; mkdir -p "$config"
  stderr="$dir/default-on.err"
  fb=$(make_release_fakebin "$dir" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = on ] || fail "an absent presentation config at the floor must resolve on, got '$verdict'"
  [ ! -s "$stderr" ] || fail "a supported release must not warn: $(cat "$stderr")"
  verdict=$(presentation_enabled_verdict "$dir/missing-config-dir" "$fb" 2>/dev/null)
  [ "$verdict" = on ] || fail "a missing config dir at the floor must resolve on, got '$verdict'"
  pass "herdr presentation: a home that set nothing gets the projection by default at or above the floor"
}

test_presentation_default_falls_back_below_the_floor() {
  local dir config fb verdict stderr
  dir="$TMP_ROOT/presentation-below-floor"; config="$dir/config"; mkdir -p "$config"
  stderr="$dir/below-floor.err"
  fb=$(make_release_fakebin "$dir" "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = off ] || fail "an unconfigured home below the floor must fall back flat, got '$verdict'"
  assert_contains "$(cat "$stderr")" "$BELOW_FLOOR_VERSION" \
    "the below-floor warning must name the running release"
  assert_contains "$(cat "$stderr")" "0.8.0" \
    "the below-floor warning must name the upgrade that fixes it"
  pass "herdr presentation: an unconfigured home below the floor falls back flat with one naming warning"
}

test_presentation_unreadable_release_falls_back() {
  local dir config fb verdict stderr
  dir="$TMP_ROOT/presentation-unreadable"; config="$dir/config"; mkdir -p "$config"
  stderr="$dir/unreadable.err"
  fb=$(make_release_fakebin "$dir" unreadable unreadable)
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = off ] || fail "an unverifiable release must fall back flat, got '$verdict'"
  assert_contains "$(cat "$stderr")" "could not be read" \
    "an unverifiable release must say the floor could not be checked"
  pass "herdr presentation: an unreadable client release falls back flat instead of guessing"
}

test_presentation_explicit_opt_in_survives_the_floor() {
  local dir config fb verdict stderr
  dir="$TMP_ROOT/presentation-legacy-opt-in"; config="$dir/config"; mkdir -p "$config"
  stderr="$dir/legacy.err"
  fb=$(make_release_fakebin "$dir" "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  # The historical opt-in was a bare `touch` of the file, so an empty file must
  # keep meaning a deliberate on - and must not warn, or every migrated home
  # warns on every spawn.
  : > "$config/herdr-presentation-spaces"
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = on ] || fail "a legacy empty opt-in file must resolve on below the floor, got '$verdict'"
  [ ! -s "$stderr" ] || fail "a legacy empty opt-in file must not warn: $(cat "$stderr")"
  printf '\n \n' > "$config/herdr-presentation-spaces"
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = on ] || fail "a whitespace-only opt-in file must resolve on below the floor, got '$verdict'"
  [ ! -s "$stderr" ] || fail "a whitespace-only opt-in file must not warn: $(cat "$stderr")"
  printf 'on\n' > "$config/herdr-presentation-spaces"
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = on ] || fail "an explicit on must resolve on below the floor, got '$verdict'"
  [ ! -s "$stderr" ] || fail "an explicit opt-in must not warn: $(cat "$stderr")"
  pass "herdr presentation: a deliberate opt-in is never silently downgraded below the floor"
}

test_presentation_explicit_off_opts_out() {
  local dir config fb verdict value
  dir="$TMP_ROOT/presentation-opt-out"; config="$dir/config"; mkdir -p "$config"
  fb=$(make_release_fakebin "$dir" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION")
  for value in 'off' 'off
' '  off  ' 'OFF' 'Off'; do
    printf '%s' "$value" > "$config/herdr-presentation-spaces"
    verdict=$(presentation_enabled_verdict "$config" "$fb" 2>/dev/null)
    [ "$verdict" = off ] || fail "the opt-out value '$value' must resolve off, got '$verdict'"
  done
  pass "herdr presentation: an explicit off opts the home out"
}

test_presentation_unrecognized_value_warns_and_keeps_the_default() {
  local dir config fb verdict stderr
  dir="$TMP_ROOT/presentation-unrecognized"; config="$dir/config"; mkdir -p "$config"
  stderr="$dir/unrecognized.err"
  printf 'disabled\n' > "$config/herdr-presentation-spaces"
  fb=$(make_release_fakebin "$dir" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = on ] || fail "an unrecognized value at the floor must keep the default on, got '$verdict'"
  assert_contains "$(cat "$stderr")" 'unrecognized value' \
    "an unrecognized value must warn so a typo is visible"
  # A typo is not a deliberate opt-in, so below the floor it takes the default's
  # flat fallback rather than forcing a focus-unsafe projection.
  fb=$(make_release_fakebin "$dir" "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = off ] || fail "an unrecognized value below the floor must follow the default, got '$verdict'"
  pass "herdr presentation: an unrecognized value warns and follows the default instead of failing a spawn"
}

test_presentation_floor_warning_is_one_per_release() {
  local dir config state fb first second third
  dir="$TMP_ROOT/presentation-floor-dedupe"; config="$dir/config"; state="$dir/state"
  mkdir -p "$config" "$state"
  fb=$(make_release_fakebin "$dir" "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  first=$(presentation_enabled_verdict "$config" "$fb" "$state" 2>&1 >/dev/null)
  second=$(presentation_enabled_verdict "$config" "$fb" "$state" 2>&1 >/dev/null)
  [ -n "$first" ] || fail "the first below-floor spawn must warn"
  [ -z "$second" ] || fail "a repeat spawn on the same release must not warn again: $second"
  # A downgrade or an upgrade is a different release, so it is announced again.
  fb=$(make_release_fakebin "$dir/other" 16 0.7.3)
  third=$(presentation_enabled_verdict "$config" "$fb" "$state" 2>&1 >/dev/null)
  assert_contains "$third" '0.7.3' "a changed release must re-announce the floor"
  pass "herdr presentation: the below-floor warning is one per home per release, not one per spawn"
}

test_presentation_floor_warning_marker_is_atomic_and_symlink_safe() {
  local dir config state fb i pid warnings marker outside symlink_warning failure_state failure_warning
  local pids=()
  dir="$TMP_ROOT/presentation-floor-marker-safety"; config="$dir/config"; state="$dir/state"
  mkdir -p "$config" "$state"
  fb=$(make_release_fakebin "$dir" "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  for i in {1..20}; do
    presentation_enabled_verdict "$config" "$fb" "$state" \
      >"$dir/concurrent-$i.out" 2>"$dir/concurrent-$i.err" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || fail "a concurrent presentation-floor verdict failed"
  done
  warnings=$(awk '/^warning:/ { count++ } END { print count + 0 }' "$dir"/concurrent-*.err)
  [ "$warnings" -eq 1 ] \
    || fail "concurrent below-floor spawns must publish exactly one warning, got $warnings"

  state="$dir/symlink-state"
  mkdir -p "$state"
  marker="$state/.herdr-presentation-floor-version-0-7-5--protocol-17-"
  outside="$dir/symlink-target"
  ln -s "$outside" "$marker"
  symlink_warning=$(presentation_enabled_verdict "$config" "$fb" "$state" 2>&1 >/dev/null)
  [ -z "$symlink_warning" ] \
    || fail "an existing dangling marker symlink must be treated as already claimed: $symlink_warning"
  [ ! -e "$outside" ] \
    || fail "publishing the floor marker followed a dangling symlink outside the state directory"

  failure_state="$dir/failure-state"
  mkdir -p "$failure_state"
  cat > "$fb/ln" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fb/ln"
  failure_warning=$(presentation_enabled_verdict "$config" "$fb" "$failure_state" 2>&1 >/dev/null)
  [ -n "$failure_warning" ] \
    || fail "a non-collision marker publication failure must not suppress the warning"
  pass "herdr presentation: warning marker publication is atomic, symlink-safe, and fails visible"
}

test_presentation_running_server_release_is_load_bearing() {
  local dir config fb verdict stderr
  dir="$TMP_ROOT/presentation-running-server-floor"; config="$dir/config"
  mkdir -p "$config"
  stderr="$dir/server.err"

  fb=$(make_release_fakebin "$dir/old-server" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION" \
    true "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" "" stale-session 2>"$stderr")
  [ "$verdict" = off ] \
    || fail "an old running server must keep a new client below the presentation floor, got '$verdict'"
  assert_contains "$(cat "$stderr")" "server version $BELOW_FLOOR_VERSION" \
    "the floor warning must name the selected running server release"

  fb=$(make_release_fakebin "$dir/new-server" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION" \
    true "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" "" current-session 2>"$stderr")
  [ "$verdict" = on ] \
    || fail "an at-floor client and running server must project, got '$verdict'"
  [ ! -s "$stderr" ] || fail "an at-floor client and running server must not warn: $(cat "$stderr")"

  fb=$(make_release_fakebin "$dir/old-client" "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION" \
    true "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" "" current-session 2>"$stderr")
  [ "$verdict" = off ] \
    || fail "a below-floor client must conservatively block projection despite an at-floor server, got '$verdict'"
  assert_contains "$(cat "$stderr")" "$BELOW_FLOOR_VERSION" \
    "the conservative client/server warning must name the below-floor client"

  printf 'on\n' > "$config/herdr-presentation-spaces"
  fb=$(make_release_fakebin "$dir/opt-in-old-server" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION" \
    true "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" "" stale-session 2>"$stderr")
  [ "$verdict" = on ] \
    || fail "an explicit opt-in must survive a below-floor running server, got '$verdict'"
  [ ! -s "$stderr" ] || fail "an explicit opt-in below the server floor must not warn: $(cat "$stderr")"
  unlink "$config/herdr-presentation-spaces"

  fb=$(make_release_fakebin "$dir/unknown-server" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION" unknown)
  verdict=$(presentation_enabled_verdict "$config" "$fb" "" unknown-session 2>"$stderr")
  [ "$verdict" = off ] \
    || fail "an unreadable selected-session server state must fail flat instead of substituting the client, got '$verdict'"
  assert_contains "$(cat "$stderr")" "could not be read" \
    "an unreadable selected-session server state must warn"
  pass "herdr presentation: client and selected server floors compose conservatively without overriding explicit opt-in"
}

# The floor classifier is pure, so these cases pin it against every release
# identity measured from the real binaries plus the deliberate signal-loss and
# signal-divergence shapes that decide which signal carried a verdict.
release_floor_verdict() {  # <protocol> <version> -> above|below|indeterminate
  bash -c '
    . "$0/bin/backends/herdr.sh"
    status=0
    fm_backend_herdr_release_floor_verdict "$1" "$2" || status=$?
    case "$status" in
      0) printf "above\n" ;;
      1) printf "below\n" ;;
      *) printf "indeterminate\n" ;;
    esac
  ' "$ROOT" "$1" "$2"
}

test_release_floor_verdict_matches_the_measured_releases() {
  local expected protocol version got case_line
  # protocol<TAB>version<TAB>expected, from the 2026-08-05 measurement.
  while IFS=$'\t' read -r protocol version expected; do
    [ -n "$expected" ] || continue
    got=$(release_floor_verdict "$protocol" "$version")
    [ "$got" = "$expected" ] \
      || fail "protocol '$protocol' version '$version' should be $expected, got $got"
  done <<'CASES'
16	0.7.3	below
16	0.7.4	below
17	0.7.5	below
17	0.7.5-preview.2026-07-21-0f10e1453a7f	below
18	0.7.5-preview.2026-07-29-44b3adb12552	below
19	0.8.0-preview.2026-08-04-d78e3d3b5126	above
19	0.8.0	above
20	0.9.0	above
CASES
  case_line=$(release_floor_verdict 19 '')
  [ "$case_line" = above ] || fail "a floor protocol alone must carry an above verdict, got $case_line"
  case_line=$(release_floor_verdict 17 '')
  [ "$case_line" = below ] || fail "a below-floor protocol alone must carry a below verdict, got $case_line"
  case_line=$(release_floor_verdict '' 0.8.0)
  [ "$case_line" = above ] || fail "a floor version alone must carry an above verdict, got $case_line"
  case_line=$(release_floor_verdict '' 0.7.5)
  [ "$case_line" = below ] || fail "a below-floor version alone must carry a below verdict, got $case_line"
  case_line=$(release_floor_verdict '' '')
  [ "$case_line" = indeterminate ] || fail "losing both signals must be indeterminate, got $case_line"
  case_line=$(release_floor_verdict 'not-a-number' 'not-a-version')
  [ "$case_line" = indeterminate ] || fail "two unparseable signals must be indeterminate, got $case_line"
  pass "herdr presentation floor: every measured release, and each signal alone, classifies correctly"
}

test_release_floor_verdict_survives_losing_either_signal() {
  local got
  # Divergence, asserted explicitly so neither half can go vacuous: with a
  # floor protocol and a below-floor version the protocol carries the verdict,
  # and removing it flips the answer, which proves it was load-bearing there.
  got=$(release_floor_verdict 19 0.7.5)
  [ "$got" = above ] || fail "the protocol signal must carry an above verdict on its own, got $got"
  got=$(release_floor_verdict '' 0.7.5)
  [ "$got" = below ] || fail "the divergent case must flip once the protocol signal is gone, got $got"
  # The mirror image: a floor version with a stale protocol, and the same
  # removal check.
  got=$(release_floor_verdict 16 0.9.0)
  [ "$got" = above ] || fail "the version signal must carry an above verdict on its own, got $got"
  got=$(release_floor_verdict 16 '')
  [ "$got" = below ] || fail "the divergent case must flip once the version signal is gone, got $got"
  pass "herdr presentation floor: either signal alone can carry an above verdict, and each divergence is real"
}

test_presentation_preference_reports_three_distinct_states() {
  local dir config got
  dir="$TMP_ROOT/presentation-preference"; config="$dir/config"; mkdir -p "$config"
  preference() {
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_preference "$1"' "$ROOT" "$1" 2>/dev/null
  }
  got=$(preference "$config")
  [ "$got" = default ] || fail "an absent file must report the default, got '$got'"
  printf 'on\n' > "$config/herdr-presentation-spaces"
  got=$(preference "$config")
  [ "$got" = on ] || fail "an explicit on must report on, got '$got'"
  printf 'off\n' > "$config/herdr-presentation-spaces"
  got=$(preference "$config")
  [ "$got" = off ] || fail "an explicit off must report off, got '$got'"
  printf 'disabled\n' > "$config/herdr-presentation-spaces"
  got=$(preference "$config")
  [ "$got" = default ] || fail "an unrecognized value must report the default, got '$got'"
  pass "herdr presentation: config parsing separates a deliberate choice from an unconfigured default"
}

test_projection_journal_is_atomic_and_uses_128_bit_token() {
  local dir state out token parsed status
  dir="$TMP_ROOT/projection-journal"; state="$dir/state"; mkdir -p "$state"
  out=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    token=$(fm_backend_herdr_projection_journal_create "$1" task-p1) || exit 1
    parsed=$(fm_backend_herdr_projection_journal_token "$1/task-p1.herdr-presentation" task-p1) || exit 1
    printf "%s\n%s\n" "$token" "$parsed"
    fm_backend_herdr_projection_journal_create "$1" task-p1 >/dev/null 2>&1
  ' "$ROOT" "$state" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a second presentation journal publication must fail instead of overwriting the first"
  token=$(printf '%s\n' "$out" | sed -n '1p')
  parsed=$(printf '%s\n' "$out" | sed -n '2p')
  [ "$token" = "$parsed" ] || fail "journal round-trip changed the projection id"
  [ "${#token}" -eq 22 ] || fail "a 128-bit base64url projection id must be 22 characters, got '${#token}'"
  case "$token" in *[!A-Za-z0-9_-]*) fail "projection id was not base64url: $token" ;; esac
  [ "$(wc -l < "$state/task-p1.herdr-presentation" | tr -d '[:space:]')" = 3 ] \
    || fail "presentation journal must contain only version, task id, and projection id"
  pass "herdr presentation journal: atomically publishes one non-authoritative 128-bit correlator and refuses overwrite"
}

test_projection_journal_v2_binds_and_advances_exact_endpoint() {
  local dir state home home_real out token
  dir="$TMP_ROOT/projection-journal-v2"; state="$dir/state"; home="$dir/home"
  mkdir -p "$state" "$home"
  home_real=$(cd "$home" && pwd -P)
  out=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    token=$(fm_backend_herdr_projection_journal_create "$1" fm-hibit-r1) || exit 1
    journal="$1/fm-hibit-r1.herdr-presentation"
    home=$(fm_backend_herdr_projection_home_identity "$2") || exit 1
    label=$(fm_backend_herdr_projection_workspace_label fm-hibit-r1 "$token")
    fm_backend_herdr_projection_journal_bind \
      "$journal" fm-hibit-r1 "$home" lab-session w2 w2:t2 lab-session:w2:p2 w1 firstmate "$label" fm-fm-hibit-r1 || exit 1
    fm_backend_herdr_projection_journal_snapshot "$journal" fm-hibit-r1 || exit 1
    printf "%s|%s|%s|%s|%s|%s|%s\n" \
      "$FM_BACKEND_HERDR_JOURNAL_VERSION" \
      "$FM_BACKEND_HERDR_JOURNAL_HOME" \
      "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" \
      "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" \
      "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" \
      "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID" \
      "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL"
    fm_backend_herdr_projection_journal_replace_endpoint \
      "$journal" fm-hibit-r1 w2:t2 lab-session:w2:p2 w2:t3 lab-session:w2:p3 || exit 1
    fm_backend_herdr_projection_journal_snapshot "$journal" fm-hibit-r1 || exit 1
    printf "%s|%s\n" "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" "$FM_BACKEND_HERDR_JOURNAL_PANE_ID"
  ' "$ROOT" "$state" "$home") || fail "version 2 projection journal binding failed"
  token=$(sed -n 's/^projection_id=//p' "$state/fm-hibit-r1.herdr-presentation")
  [ "$(printf '%s\n' "$out" | sed -n '1p')" = "2|$home_real|w2|w2:t2|w2:p2|w1|└ hibit-r1 · p:$token" ] \
    || fail "version 2 projection journal did not retain exact home/endpoint/parent binding: $out"
  [ "$(printf '%s\n' "$out" | sed -n '2p')" = "w2:t3|w2:p3" ] \
    || fail "version 2 projection journal did not advance the exact replacement endpoint: $out"
  [ "$(wc -l < "$state/fm-hibit-r1.herdr-presentation" | tr -d '[:space:]')" = 12 ] \
    || fail "version 2 projection journal must have exactly 12 fields"
  printf 'pane_id=duplicate\n' >> "$state/fm-hibit-r1.herdr-presentation"
  if bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_journal_snapshot "$1" fm-hibit-r1' \
    "$ROOT" "$state/fm-hibit-r1.herdr-presentation"; then
    fail "duplicate version 2 journal fields must be ambiguous"
  fi
  pass "herdr presentation journal: version 2 binds exact home/endpoint/parent identities and advances atomically"
}

test_projection_create_uses_exact_response_ids_and_leaves_one_task_pane() {
  local dir state log resp fb out token journal
  dir="$TMP_ROOT/projection-create"; state="$dir/state"; mkdir -p "$dir/responses" "$state"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"workspace":{"workspace_id":"w9"},"tab":{"tab_id":"w9:t1"},"root_pane":{"pane_id":"fmtest:w9:p1"}}}\n' > "$resp/1.out"
  printf '{"result":{"tab":{"tab_id":"w9:t2"},"root_pane":{"pane_id":"fmtest:w9:p2"}}}\n' > "$resp/2.out"
  printf '{"result":{"tabs":[{"tab_id":"w9:t1","label":"1","workspace_id":"w9"},{"tab_id":"w9:t2","label":"fm-task-p2","workspace_id":"w9"}]}}\n' > "$resp/3.out"
  printf '{"result":{"panes":[{"pane_id":"fmtest:w9:p1","tab_id":"w9:t1"},{"pane_id":"fmtest:w9:p2","tab_id":"w9:t2"}]}}\n' > "$resp/4.out"
  printf '{"error":{"code":"agent_not_found"}}\n' > "$resp/5.out"
  printf '{"result":{"pane":{"pane_id":"fmtest:w9:p1","tab_id":"w9:t1","workspace_id":"w9"}}}\n' > "$resp/6.out"
  # The emptying-close plan's tab list proves the seeded prune is NOT
  # workspace-emptying (the task tab remains), so the close stays plain.
  printf '{"result":{"tabs":[{"tab_id":"w9:t1","label":"1","workspace_id":"w9"},{"tab_id":"w9:t2","label":"fm-task-p2","workspace_id":"w9"}]}}\n' > "$resp/7.out"
  printf '{"error":{"code":"pane_not_found"}}\n' > "$resp/9.out"
  printf '{"result":{"tabs":[{"tab_id":"w9:t2","label":"fm-task-p2","workspace_id":"w9"}]}}\n' > "$resp/10.out"
  printf '{"result":{"panes":[{"pane_id":"fmtest:w9:p2","tab_id":"w9:t2"}]}}\n' > "$resp/11.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" HERDR_SESSION=fmtest \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_projection_focus_snapshot() { printf "captain-ws\tcaptain-tab"; }
      fm_backend_herdr_projection_focus_restore() { return 0; }
      token=$(fm_backend_herdr_projection_journal_create "$1" task-p2) || exit 1
      label=$(fm_backend_herdr_projection_workspace_label task-p2 "$token")
      fm_backend_herdr_projection_create_task /tmp/proj "$label" fm-task-p2 || exit 1
      printf "%s %s %s %s %s\n" \
        "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
        "$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID" \
        "$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID" \
        "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" \
        "$FM_BACKEND_HERDR_PROJECTION_PANE_ID"
    ' "$ROOT" "$state") || fail "projection create should succeed from complete exact responses"
  [ "$out" = "w9 w9:t1 w9:p1 w9:t2 w9:p2" ] || fail "projection create did not retain exact response IDs: $out"
  journal="$state/task-p2.herdr-presentation"
  token=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_journal_token "$1" task-p2' "$ROOT" "$journal") \
    || fail "projection journal was not readable"
  assert_contains "$(cat "$log")" $'workspace\x1fcreate\x1f--cwd\x1f/tmp/proj\x1f--label\x1f└ task-p2 · p:'"$token"$'\x1f--no-focus' \
    "projection workspace create did not use the corner label, full token, and --no-focus"
  assert_contains "$(cat "$log")" $'tab\x1fcreate\x1f--workspace\x1fw9\x1f--cwd\x1f/tmp/proj\x1f--label\x1ffm-task-p2\x1f--no-focus' \
    "projection task tab did not target the exact new workspace"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw9:p1' \
    "projection create did not prune the exact seeded root pane"
  assert_not_contains "$(cat "$log")" $'workspace\x1fclose' \
    "projection create must never call workspace close"
  pass "herdr presentation create: session-prefixed response pane ids normalize with no workspace-close authority"
}

test_projection_create_never_closes_a_concurrent_same_label_tab() {
  local dir log resp fb out status
  dir="$TMP_ROOT/projection-concurrent-tab"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"workspace":{"workspace_id":"w9"},"tab":{"tab_id":"w9:t1"},"root_pane":{"pane_id":"w9:p1"}}}\n' > "$resp/1.out"
  printf '{"result":{"tab":{"tab_id":"w9:t2"},"root_pane":{"pane_id":"w9:p2"}}}\n' > "$resp/2.out"
  printf '{"result":{"tabs":[{"tab_id":"w9:t1","label":"1","workspace_id":"w9"},{"tab_id":"w9:t2","label":"fm-task-p2","workspace_id":"w9"},{"tab_id":"w9:t3","label":"fm-task-p2","workspace_id":"w9"}]}}\n' > "$resp/3.out"
  printf '{"result":{"panes":[{"pane_id":"w9:p1","tab_id":"w9:t1"},{"pane_id":"w9:p2","tab_id":"w9:t2"},{"pane_id":"w9:p3","tab_id":"w9:t3"}]}}\n' > "$resp/4.out"
  printf '{"error":{"code":"agent_not_found"}}\n' > "$resp/5.out"
  printf '{"result":{"pane":{"pane_id":"w9:p1","tab_id":"w9:t1","workspace_id":"w9"}}}\n' > "$resp/6.out"
  printf '{"result":{"tabs":[{"tab_id":"w9:t1","label":"1","workspace_id":"w9"},{"tab_id":"w9:t2","label":"fm-task-p2","workspace_id":"w9"},{"tab_id":"w9:t3","label":"fm-task-p2","workspace_id":"w9"}]}}\n' > "$resp/7.out"
  printf '{"error":{"code":"pane_not_found"}}\n' > "$resp/9.out"
  printf '{"result":{"tabs":[{"tab_id":"w9:t2","label":"fm-task-p2","workspace_id":"w9"},{"tab_id":"w9:t3","label":"fm-task-p2","workspace_id":"w9"}]}}\n' > "$resp/10.out"
  printf '{"result":{"panes":[{"pane_id":"w9:p2","tab_id":"w9:t2"},{"pane_id":"w9:p3","tab_id":"w9:t3"}]}}\n' > "$resp/11.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "captain-ws\tcaptain-tab"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_create_task /tmp/proj label fm-task-p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a concurrent tab should prevent exact one-pane projection convergence"
  assert_contains "$out" "did not converge to exactly one task pane" \
    "projection did not report the concurrent shape"
  assert_not_contains "$(cat "$log")" $'tab\x1fclose\x1fw9:t3' \
    "projection closed a concurrent same-label tab"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose\x1fw9:p3' \
    "projection closed a concurrent same-label pane"
  pass "herdr presentation create: concurrent same-label tabs are never prune targets"
}

test_projection_focus_snapshot_requires_exact_workspace_and_tab() {
  local dir log resp fb out
  dir="$TMP_ROOT/projection-focus-snapshot"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":true}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":false},{"tab_id":"w2:t2","focused":true}]}}' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot fmtest' "$ROOT") \
    || fail "an exact active workspace and tab should produce a focus snapshot"
  [ "$out" = $'w2\tw2:t2' ] || fail "focus snapshot did not preserve exact response IDs: $out"
  pass "herdr presentation focus: snapshot requires one exact active workspace and tab"
}

test_projection_close_restores_exact_prior_focus() {
  local dir log resp fb out status
  dir="$TMP_ROOT/projection-focus-restore"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":true},{"workspace_id":"w9","active_tab_id":"w9:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":false},{"tab_id":"w2:t2","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9"}}}' > "$resp/3.out"
  # The emptying-close plan sees a second tab in w9, so the close stays plain
  # and the exact-tab restore backstop is what reclaims the stolen focus.
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","workspace_id":"w9"},{"tab_id":"w9:t2","workspace_id":"w9"}]}}' > "$resp/4.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/6.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":true}]}}' > "$resp/7.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2","focused":true}}}' > "$resp/10.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":false},{"tab_id":"w2:t2","focused":true}]}}' > "$resp/12.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "an exact non-active projection close should succeed after restoring focus: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw9:p2' \
    "focus-preserving cleanup did not close only the exact projection pane"
  assert_contains "$(cat "$log")" $'tab\x1ffocus\x1fw2:t2' \
    "focus-preserving cleanup did not restore the exact prior active tab"
  assert_not_contains "$(cat "$log")" $'workspace\x1fclose' \
    "focus-preserving cleanup introduced workspace-close authority"
  pass "herdr presentation focus: exact pane close restores the exact prior workspace and tab"
}

test_projection_close_refuses_active_tab() {
  local dir log resp fb out status
  dir="$TMP_ROOT/projection-focus-active-refusal"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w9","active_tab_id":"w9:t2","focused":true}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t2","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","workspace_id":"w9"},{"tab_id":"w9:t2","workspace_id":"w9"}]}}' > "$resp/4.out"
  cp "$resp/1.out" "$resp/5.out"
  cp "$resp/2.out" "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_FAKE_HERDR_FOREGROUND_REASON=cleared \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "cleanup must refuse when a live client is viewing the active tab"
  assert_contains "$out" "target is the captain's active tab" \
    "active-tab cleanup refusal did not explain the focus-safety boundary"
  assert_contains "$(cat "$log")" $'terminal\x1ftitle\x1fclear' \
    "live-client active-tab refusal did not probe foreground attachment"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' \
    "active-tab cleanup refusal still closed the pane"
  pass "herdr presentation focus: cleanup refuses rather than close the tab a live client is viewing"
}

test_projection_close_refuses_unknown_foreground_reason() {
  local dir events out status
  dir="$TMP_ROOT/projection-focus-unknown-foreground"; mkdir -p "$dir"
  events="$dir/events"; : > "$events"
  out=$(ROOT="$ROOT" EVENTS="$events" bash -c '
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_projection_focus_snapshot() { printf "w9\tw9:t2"; }
    fm_backend_herdr_emptying_close_plan() { printf "plain\n"; }
    fm_backend_herdr_cli() {
      case "$2 $3" in
        "pane get") printf "{\"result\":{\"pane\":{\"pane_id\":\"w9:p2\",\"tab_id\":\"w9:t2\",\"workspace_id\":\"w9\"}}}\n" ;;
        "terminal title") printf "{\"result\":{\"reason\":\"set\"}}\n" ;;
        "pane close") printf "close\n" >> "$EVENTS" ;;
      esac
    }
    fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2
  ' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an unexpected foreground response must not authorize an active-tab close"
  [ ! -s "$events" ] || fail "unexpected foreground response still closed the pane"
  assert_contains "$out" "could not verify whether a foreground client is viewing the target tab" \
    "unexpected foreground response did not take the fail-closed unknown path"
  pass "herdr presentation focus: unexpected foreground-client reasons fail closed"
}

test_projection_close_allows_stale_active_tab_without_foreground_client() {
  local dir log resp fb out status
  dir="$TMP_ROOT/projection-focus-stale-active-allow"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w9","active_tab_id":"w9:t2","focused":true}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t2","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","workspace_id":"w9"},{"tab_id":"w9:t2","workspace_id":"w9"}]}}' > "$resp/4.out"
  : > "$resp/5.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "cleanup must close a persisted-focused tab when no live client is attached: $out"
  assert_not_contains "$out" "target is the captain's active tab" \
    "detached persisted-focus close still used the live-viewer refusal"
  assert_contains "$(cat "$log")" $'terminal\x1ftitle\x1fclear' \
    "detached persisted-focus close did not probe foreground attachment"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw9:p2' \
    "detached persisted-focus close did not close the exact pane"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' \
    "detached persisted-focus close restored a persisted pointer with no live viewer"
  pass "herdr presentation focus: cleanup closes a persisted-focused tab when no live client is attached"
}

test_projection_close_reports_focus_restore_failure() {
  local dir log resp fb out status
  dir="$TMP_ROOT/projection-focus-restore-failure"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w9","active_tab_id":"w9:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","workspace_id":"w9"},{"tab_id":"w9:t2","workspace_id":"w9"}]}}' > "$resp/4.out"
  : > "$resp/5.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/6.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true}]}}' > "$resp/7.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t1","workspace_id":"w1"}}}' > "$resp/9.out"
  : > "$resp/10.out"
  cp "$resp/7.out" "$resp/11.out"
  cp "$resp/8.out" "$resp/12.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "cleanup did not distinguish post-close focus uncertainty: $status"
  assert_contains "$out" "did not restore the exact prior workspace and tab" \
    "focus restoration failure was not reported"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw9:p2' \
    "focus restoration failure fixture did not reach the close boundary"
  pass "herdr presentation focus: pane close fails when exact focus restoration fails"
}

test_projection_close_rechecks_required_agent_state_at_boundary() {
  local dir log out status
  dir="$TMP_ROOT/projection-close-agent-boundary"; mkdir -p "$dir"
  log="$dir/log"; : > "$log"
  out=$(ROOT="$ROOT" LOG="$log" bash -c '
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_projection_focus_snapshot() { printf "w1\tw1:t1"; }
    fm_backend_herdr_pane_agent_state() { printf live; }
    fm_backend_herdr_cli() {
      printf "%s\n" "$*" >> "$LOG"
      case "$2 $3" in
        "pane get") printf "{\"result\":{\"pane\":{\"pane_id\":\"w9:p2\",\"tab_id\":\"w9:t2\"}}}\n" ;;
      esac
    }
    set +e
    fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2 no-agent
    rc=$?
    set -e
    printf "%s:%s" "$rc" "$FM_BACKEND_HERDR_PROJECTION_CLOSE_AGENT_STATE"
  ')
  status=${out%%:*}
  [ "$status" -ne 0 ] && [ "$out" = "$status:live" ] \
    || fail "required close-boundary agent state did not refuse live: $out"
  assert_not_contains "$(cat "$log")" "pane close" \
    "required close-boundary agent state still closed a live pane"
  pass "herdr presentation reclaim: live agent state at the close boundary refuses mutation"
}

test_projection_close_rechecks_foreground_client_after_agent_validation() {
  local dir events attached out status
  dir="$TMP_ROOT/projection-close-foreground-boundary"; mkdir -p "$dir"
  events="$dir/events"; attached="$dir/attached"; : > "$events"
  out=$(ROOT="$ROOT" EVENTS="$events" ATTACHED="$attached" bash -c '
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_projection_focus_snapshot() { printf "w9\tw9:t2"; }
    fm_backend_herdr_pane_agent_state() {
      printf "agent\n" >> "$EVENTS"
      : > "$ATTACHED"
      printf no-agent
    }
    fm_backend_herdr_cli() {
      case "$2 $3" in
        "pane get") printf "{\"result\":{\"pane\":{\"pane_id\":\"w9:p2\",\"tab_id\":\"w9:t2\"}}}\n" ;;
        "terminal title")
          printf "foreground\n" >> "$EVENTS"
          if [ -e "$ATTACHED" ]; then
            printf "{\"result\":{\"reason\":\"cleared\"}}\n"
          else
            printf "{\"result\":{\"reason\":\"no_foreground_client\"}}\n"
          fi
          ;;
        "pane close") printf "close\n" >> "$EVENTS" ;;
      esac
    }
    fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2 no-agent
  ' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a client attaching during agent validation must defer the active-tab close"
  [ "$(cat "$events")" = $'agent\nforeground' ] \
    || fail "foreground attachment was not checked immediately after agent validation: $(cat "$events")"
  assert_contains "$out" "target is the captain's active tab" \
    "fresh foreground-client refusal did not explain the active-tab boundary"
  pass "herdr presentation focus: active-tab attachment is rechecked after agent validation"
}

test_projection_close_rechecks_target_focus_after_planning() {
  local dir events focused out status
  dir="$TMP_ROOT/projection-close-focus-switch"; mkdir -p "$dir"
  events="$dir/events"; focused="$dir/focused"; : > "$events"
  out=$(ROOT="$ROOT" EVENTS="$events" FOCUSED="$focused" bash -c '
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_projection_focus_snapshot() {
      if [ -e "$FOCUSED" ]; then
        printf "w9\tw9:t2"
      else
        printf "w1\tw1:t1"
      fi
    }
    fm_backend_herdr_emptying_close_plan() {
      : > "$FOCUSED"
      printf "plain\n"
    }
    fm_backend_herdr_cli() {
      case "$2 $3" in
        "pane get") printf "{\"result\":{\"pane\":{\"pane_id\":\"w9:p2\",\"tab_id\":\"w9:t2\",\"workspace_id\":\"w9\"}}}\n" ;;
        "terminal title") printf "{\"result\":{\"reason\":\"cleared\"}}\n" ;;
        "pane close") printf "close\n" >> "$EVENTS" ;;
      esac
    }
    fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2
  ' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a target focused during planning must defer the pane close"
  [ ! -s "$events" ] || fail "the focus-switched target was still mutated: $(cat "$events")"
  assert_contains "$out" "target is the captain's active tab" \
    "focus-switch refusal did not explain the active-tab boundary"
  pass "herdr presentation focus: pre-close checkpoint catches a target focused during planning"
}

test_projection_close_preserves_live_focus_that_switched_away_from_target() {
  local dir events sample out status
  dir="$TMP_ROOT/projection-close-focus-switch-away"; mkdir -p "$dir"
  events="$dir/events"; sample="$dir/sample"; : > "$events"; printf '0\n' > "$sample"
  out=$(ROOT="$ROOT" EVENTS="$events" SAMPLE="$sample" bash -c '
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_projection_focus_snapshot() {
      local n
      n=$(cat "$SAMPLE"); n=$((n + 1)); printf "%s\n" "$n" > "$SAMPLE"
      if [ "$n" -eq 1 ]; then printf "w9\tw9:t2"; else printf "w1\tw1:t1"; fi
    }
    fm_backend_herdr_emptying_close_plan() { printf "plain\n"; }
    fm_backend_herdr_cli() {
      case "$2 $3" in
        "pane get") printf "{\"result\":{\"pane\":{\"pane_id\":\"w9:p2\",\"tab_id\":\"w9:t2\",\"workspace_id\":\"w9\"}}}\n" ;;
        "terminal title") printf "{\"result\":{\"reason\":\"cleared\"}}\n" ;;
      esac
    }
    fm_backend_herdr_explicit_close_pane_confirmed() { printf "close\n" >> "$EVENTS"; }
    fm_backend_herdr_projection_focus_restore() { printf "restore:%s\n" "$2" >> "$EVENTS"; }
    fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2
  ' 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a client switching from the target to another tab should allow the target close: $out"
  [ "$(cat "$events")" = $'close\nrestore:w1\tw1:t1' ] \
    || fail "close did not preserve the live client's fresh non-target focus: $(cat "$events")"
  pass "herdr presentation focus: close preserves a live client that switches away from the target during planning"
}

# --- emptying-close focus-safe removal (Herdr 0.7.5 #1621 mitigation) ------
#
# The fixtures below model the verified 0.7.5 rules: an explicit close that
# empties a non-focused workspace moves focus to that workspace's neighbor,
# while a pane-death removal preserves focus whenever the dying workspace
# sits behind the focused one (or the focused one is last).

# make_death_lab <dir> <shell-pid>: a fake ps and a fake workspace mover for
# the pane-death close fixtures. The mover appends to $FM_FAKE_MOVER_LOG and
# exits 9 unless $FM_FAKE_MOVER_RESPONSE names a readable response file.
make_death_lab() {  # <dir> <shell-pid>
  local dir=$1 pid=$2
  mkdir -p "$dir"
  cat > "$dir/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  "-axo pid=,ppid=") printf '1 0\n$pid 1\n' ;;
  "-p $pid -o stat=") printf 'Ss+\n' ;;
  "-p $pid -o comm=") printf -- '-zsh\n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/mover" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FM_FAKE_MOVER_LOG"
calls=$(wc -l < "$FM_FAKE_MOVER_LOG" | tr -d ' ')
if [ "$calls" -ge 2 ] && [ -f "${FM_FAKE_MOVER_RESPONSE_2:-}" ]; then
  cat "$FM_FAKE_MOVER_RESPONSE_2"
  exit 0
fi
if [ -f "$FM_FAKE_MOVER_RESPONSE" ]; then
  cat "$FM_FAKE_MOVER_RESPONSE"
  exit 0
fi
exit 9
SH
  chmod +x "$dir/ps" "$dir/mover"
  : > "$dir/mover.log"
}

death_process_info_fixture() {  # <pane> <pid>
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh"}]}}}\n' "$1" "$2" "$2" "$2"
}

test_projection_close_emptying_after_focus_uses_pane_death_without_move() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-after"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  # w1 focused; target w2 sits after it (r > a), so no repositioning is needed.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/10.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "emptying close behind focus should succeed through the pane-death path: $out"
  [ ! -s "$dir/mover.log" ] || fail "a close already behind focus invoked the workspace mover"
  assert_contains "$(cat "$log")" $'pane\x1fprocess-info' "pane-death close skipped the idle-shell proof"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "emptying close behind focus used the focus-unsafe explicit close"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' "focus moved despite the pane-death removal"
  pass "herdr presentation cleanup: emptying close behind focus ends the exact shell without a move or focus change"
}

test_projection_close_emptying_before_focus_repositions_then_uses_pane_death() {
  local dir log resp fb out status bgpid mover_line
  dir="$TMP_ROOT/close-death-before"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Target w1 sits BEFORE the focused w2, which is not last: reposition first.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  printf '%s\n' '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}' > "$resp/7.out"
  # shellcheck disable=SC2016 # $defs is a literal JSON Schema key.
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/8.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/9.out"
  sleep 300 & bgpid=$!
  death_process_info_fixture w1:p1 "$bgpid" > "$resp/10.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/12.out"
  cp "$resp/12.out" "$resp/13.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/14.out"
  make_death_lab "$dir" "$bgpid"
  printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w2","focused":true},{"workspace_id":"w3","focused":false},{"workspace_id":"w1","focused":false}]}}' > "$dir/mover-response"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/mover-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w1:p1' "$ROOT" 2>&1)
  status=$?
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "repositioned emptying close should succeed through the pane-death path: $out"
  [ "$(cat "$dir/mover.log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w1"$'\t'"3" ] \
    || fail "the repositioning move did not target the exact doomed workspace at the list length: $(cat "$dir/mover.log")"
  mover_line=$(grep -n $'pane\x1fprocess-info' "$log" | head -1 | cut -d: -f1)
  [ -n "$mover_line" ] || fail "repositioned close skipped the idle-shell proof"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "repositioned emptying close used the focus-unsafe explicit close"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' "focus moved despite the repositioned pane-death removal"
  pass "herdr presentation cleanup: emptying close before focus moves the doomed workspace to the end and ends its exact shell"
}

test_projection_close_emptying_before_last_focus_needs_no_move() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-focus-last"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Focused w3 is LAST, so the pane-death clamp preserves it without a move.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":true}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  death_process_info_fixture w1:p1 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t1","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":true}]}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' > "$resp/10.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w1:p1' "$ROOT" 2>&1)
  status=$?
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "emptying close with last focus should succeed through the pane-death path: $out"
  [ ! -s "$dir/mover.log" ] || fail "a last-focused close invoked the workspace mover"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "last-focused emptying close used the focus-unsafe explicit close"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' "focus moved despite the pane-death removal"
  pass "herdr presentation cleanup: emptying close with the focused workspace last skips the move"
}

test_projection_close_emptying_last_workspace_needs_no_move() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-target-last"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Target w3 is already last (r > a), so no repositioning is needed.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w3:p1","tab_id":"w3:t1","workspace_id":"w3"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","workspace_id":"w3"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w3:p1","tab_id":"w3:t1"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  death_process_info_fixture w3:p1 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":false}]}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/10.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w3:p1' "$ROOT" 2>&1)
  status=$?
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "last-workspace emptying close should succeed through the pane-death path: $out"
  [ ! -s "$dir/mover.log" ] || fail "an already-last close invoked the workspace mover"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "last-workspace emptying close used the focus-unsafe explicit close"
  pass "herdr presentation cleanup: emptying close of the last workspace skips the move"
}

test_projection_close_non_emptying_stays_plain_without_proof_or_move() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-non-emptying"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","workspace_id":"w2"},{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/6.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":false}]}}' > "$resp/7.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/8.out"
  sleep 300 & bgpid=$!
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "non-emptying close should succeed through the plain close: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw2:p2' "non-emptying close did not use the plain close"
  assert_not_contains "$(cat "$log")" $'pane\x1fprocess-info' "non-emptying close ran the idle-shell proof"
  [ ! -s "$dir/mover.log" ] || fail "non-emptying close invoked the workspace mover"
  kill -0 "$bgpid" 2>/dev/null || fail "non-emptying close signaled the pane's shell"
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  pass "herdr presentation cleanup: a non-emptying close stays plain with no proof, move, or signal"
}

test_projection_close_plain_without_move_requires_structured_removal() {
  local dir log out status
  dir="$TMP_ROOT/close-plain-unconfirmed"; mkdir -p "$dir"
  log="$dir/log"; : > "$log"
  out=$(ROOT="$ROOT" LOG="$log" bash -c '
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_projection_focus_snapshot() { printf "w1\tw1:t1"; }
    fm_backend_herdr_emptying_close_plan() { printf "plain\n"; }
    fm_backend_herdr_projection_focus_restore() { return 0; }
    fm_backend_herdr_cli() {
      printf "%s\n" "$*" >> "$LOG"
      case "$2 $3" in
        "pane get") printf "{\"result\":{\"pane\":{\"pane_id\":\"w2:p2\",\"tab_id\":\"w2:t2\",\"workspace_id\":\"w2\"}}}\n" ;;
      esac
    }
    fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2
  ' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a no-move plain close must fail while structured presence remains present: $out"
  assert_contains "$(cat "$log")" "pane close w2:p2" \
    "the no-move unconfirmed regression did not reach the explicit close"
  pass "herdr presentation cleanup: no-move plain close requires structured pane removal"
}

test_projection_close_ambiguous_positions_fall_back_to_plain_close() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-ambiguous-positions"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  # The position snapshot is ambiguous: the target workspace is absent.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/6.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/10.out"
  sleep 300 & bgpid=$!
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "an ambiguous position snapshot should fall back to the plain close: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw2:p2' "ambiguous positions did not use the plain close"
  assert_not_contains "$(cat "$log")" $'pane\x1fprocess-info' "ambiguous positions ran the idle-shell proof"
  [ ! -s "$dir/mover.log" ] || fail "ambiguous positions invoked the workspace mover"
  kill -0 "$bgpid" 2>/dev/null || fail "ambiguous positions signaled the pane's shell"
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  pass "herdr presentation cleanup: an ambiguous workspace layout falls back to the plain close"
}

test_projection_close_move_failure_falls_back_to_plain_close() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-move-failure"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  printf '%s\n' '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}' > "$resp/7.out"
  # shellcheck disable=SC2016 # $defs is a literal JSON Schema key.
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/8.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/9.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/12.out"
  cp "$resp/12.out" "$resp/13.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/14.out"
  sleep 300 & bgpid=$!
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w1:p1' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a failed repositioning move should fall back to the plain close: $out"
  assert_contains "$out" "could not move the doomed workspace behind the focused one" \
    "a failed repositioning move did not warn about losing the focus-safe path"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw1:p1' "move failure did not use the plain close"
  assert_not_contains "$(cat "$log")" $'pane\x1fprocess-info' "move failure ran the idle-shell proof"
  kill -0 "$bgpid" 2>/dev/null || fail "move failure signaled the pane's shell"
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  pass "herdr presentation cleanup: a failed repositioning move falls back to the plain close with a warning"
}

test_projection_close_busy_pane_falls_back_to_plain_close() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-busy-pane"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  # The pane still has a foreground agent, so the idle-shell proof refuses.
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w2:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh"},{"pid":99999,"name":"pi","argv0":"pi"}]}}}\n' "$bgpid" "$bgpid" "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/10.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/11.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a busy pane should fall back to the plain close: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw2:p2' "a busy pane did not use the plain close"
  kill -0 "$bgpid" 2>/dev/null || fail "a busy pane close signaled the pane's shell"
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  pass "herdr presentation cleanup: a pane with a live foreground process falls back to the plain close"
}

test_projection_close_transient_prompt_helper_settles_then_uses_pane_death() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-transient-helper"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  # Sample 1: the shell is transiently redrawing its prompt (real 0.7.5 shape:
  # a helper such as starship rides along as a second foreground process).
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w2:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":99998,"name":"starship","argv":["/usr/local/bin/starship","prompt","--continuation"]},{"pid":%s,"name":"zsh","argv0":"zsh"}]}}}\n' "$bgpid" "$bgpid" "$bgpid" > "$resp/7.out"
  # Sample 2: the helper finished; the shell is provably alone and idle.
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/8.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/10.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/11.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=3 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "a transient prompt helper should settle into the pane-death path: $out"
  [ "$(grep -c $'pane\x1fprocess-info' "$log")" -ge 2 ] \
    || fail "the settle window did not retry the idle-shell proof"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "a transient prompt helper forced the focus-unsafe explicit close"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' "focus moved despite the settled pane-death removal"
  pass "herdr presentation cleanup: a transient prompt helper settles into the pane-death path instead of the plain close"
}

test_projection_close_death_escalates_sigkill_after_sighup_survival() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-escalate"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  bash -c 'trap "" HUP; sleep 300' & bgpid=$!
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"internal_error","message":"transient failure"}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/9.out"
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/10.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/12.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/13.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a SIGHUP-surviving shell should be finished by the SIGKILL escalation: $out"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "the SIGKILL escalation used the focus-unsafe explicit close"
  if kill -0 "$bgpid" 2>/dev/null; then
    kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
    fail "the SIGKILL escalation left the trapped shell alive"
  fi
  wait "$bgpid" 2>/dev/null || true
  pass "herdr presentation cleanup: a SIGHUP-surviving shell is escalated to SIGKILL before giving up"
}

test_projection_close_death_failure_falls_back_to_plain_close() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-fallback"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  bash -c 'trap "" HUP; sleep 300' & bgpid=$!
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/9.out"
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/10.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/12.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/14.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/15.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/16.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "an unkillable shell should fall back to the plain close: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw2:p2' "a failed pane-death close did not use the plain close fallback"
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  pass "herdr presentation cleanup: a failed pane-death close falls back to the plain close"
}

test_projection_close_death_still_restores_a_stolen_focus() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-restore"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/8.out"
  # The backstop still fires when the post-close snapshot disagrees.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":true}]}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' > "$resp/10.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t1","workspace_id":"w1"}}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/13.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/14.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "the pane-death close with a restored backstop should succeed: $out"
  assert_contains "$(cat "$log")" $'tab\x1ffocus\x1fw1:t1' "the backstop did not restore the exact prior tab"
  pass "herdr presentation cleanup: the exact-tab restore remains the backstop behind the pane-death close"
}

test_projection_close_death_never_sigkills_a_reused_pid() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-pid-reuse"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  # The original shell survives SIGHUP; by SIGKILL time the pane's process
  # information shows a DIFFERENT shell pid, modeling the original pid having
  # been reused by an unrelated process the pane no longer owns.
  bash -c 'trap "" HUP; sleep 300' & bgpid=$!
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/7.out"
  cp "$resp/3.out" "$resp/8.out"   # SIGHUP poll 1: pane still present
  cp "$resp/3.out" "$resp/9.out"   # SIGHUP poll 2: pane still present
  death_process_info_fixture w2:p2 99997 > "$resp/10.out"
  : > "$resp/11.out"               # fallback explicit close: pane close ok
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/12.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/13.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/14.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  if ! kill -0 "$bgpid" 2>/dev/null; then
    wait "$bgpid" 2>/dev/null || true
    fail "the SIGKILL escalation signaled a pid the exact pane no longer owns"
  fi
  kill -KILL "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "the refused escalation should fall back to the plain close: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw2:p2' "the refused escalation did not fall back to the plain close"
  pass "herdr presentation cleanup: SIGKILL never reaches a pid the exact pane no longer owns"
}

assert_projection_close_failed_removal_rolls_back_the_reposition() {
  local mode=$1 dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-move-rollback-$mode"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Doomed w1 sits BEFORE the focused w2 (not last): the plan repositions it
  # to the end; then every removal path fails, so the exact original order
  # must be restored under the same session lock and the close must fail.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  printf '%s\n' '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}' > "$resp/7.out"
  # shellcheck disable=SC2016 # $defs is a literal JSON Schema key.
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/8.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/9.out"
  bash -c 'trap "" HUP; sleep 300' & bgpid=$!
  death_process_info_fixture w1:p1 "$bgpid" > "$resp/10.out"
  if [ "$mode" = pane-gone-workspace-present ]; then
    printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/11.out"
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false},{"workspace_id":"w1","active_tab_id":"w1:t2","focused":false}]}}' > "$resp/12.out"
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/13.out"
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/14.out"
  else
    cp "$resp/3.out" "$resp/11.out"  # SIGHUP poll 1: pane still present
    cp "$resp/3.out" "$resp/12.out"  # SIGHUP poll 2: pane still present
    death_process_info_fixture w1:p1 "$bgpid" > "$resp/13.out"  # escalation resample: same owner
    cp "$resp/3.out" "$resp/14.out"  # SIGKILL poll 1: pane still present
    cp "$resp/3.out" "$resp/15.out"  # SIGKILL poll 2: pane still present
  fi
  if [ "$mode" = command-fails ]; then
    printf '9\n' > "$resp/16.exit"
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/17.out"
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/18.out"
  else
    : > "$resp/16.out"
    cp "$resp/3.out" "$resp/17.out"
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/18.out"
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/19.out"
  fi
  make_death_lab "$dir" "$bgpid"
  printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w2","focused":true},{"workspace_id":"w3","focused":false},{"workspace_id":"w1","focused":false}]}}' > "$dir/mover-response"
  printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w1","focused":false},{"workspace_id":"w2","focused":true},{"workspace_id":"w3","focused":false}]}}' > "$dir/mover-response-2"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/mover-response" \
    FM_FAKE_MOVER_RESPONSE_2="$dir/mover-response-2" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w1:p1' "$ROOT" 2>&1)
  status=$?
  kill -KILL "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "an unconfirmed removal must report failure: $out"
  [ "$(wc -l < "$dir/mover.log" | tr -d ' ')" = 2 ] \
    || fail "a failed removal did not roll the reposition back exactly once: $(cat "$dir/mover.log")"
  [ "$(sed -n '1p' "$dir/mover.log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w1"$'\t'"3" ] \
    || fail "the reposition did not move the doomed workspace to the end: $(sed -n '1p' "$dir/mover.log")"
  [ "$(sed -n '2p' "$dir/mover.log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w1"$'\t'"0" ] \
    || fail "the rollback did not restore the doomed workspace to its exact original position: $(sed -n '2p' "$dir/mover.log")"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' "a failed rolled-back removal moved focus"
}

test_projection_close_failed_removal_rolls_back_the_reposition() {
  assert_projection_close_failed_removal_rolls_back_the_reposition command-fails
  assert_projection_close_failed_removal_rolls_back_the_reposition command-succeeds-pane-present
  assert_projection_close_failed_removal_rolls_back_the_reposition pane-gone-workspace-present
  pass "herdr presentation cleanup: every unconfirmed removal restores the exact original workspace order and reports failure"
}

test_kill_emptying_non_focused_uses_pane_death() {
  local dir log resp fb out status bgpid lock_log lock_held
  dir="$TMP_ROOT/kill-death"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; lock_log="$dir/lock.log"; lock_held="$dir/lock-held"
  : > "$log"; : > "$lock_log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/10.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 FM_FAKE_LOCK_LOG="$lock_log" \
    FM_FAKE_LOCK_HELD="$lock_held" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_target_ready() { fm_backend_herdr_parse_target "$1"; }
      fm_backend_herdr_presentation_session_lock_path() { printf "%s" "$FM_FAKE_LOCK_HELD.lock"; }
      fm_lock_try_acquire() {
        printf "acquire\n" >> "$FM_FAKE_LOCK_LOG"
        : > "$FM_FAKE_LOCK_HELD"
      }
      fm_lock_release() {
        [ -e "$FM_FAKE_LOCK_HELD" ] || return 1
        rm -f "$FM_FAKE_LOCK_HELD"
        printf "release\n" >> "$FM_FAKE_LOCK_LOG"
      }
      eval "$(declare -f fm_backend_herdr_cli | sed "1s/fm_backend_herdr_cli/fm_backend_herdr_cli_locked/")"
      fm_backend_herdr_cli() {
        [ -e "$FM_FAKE_LOCK_HELD" ] || return 97
        fm_backend_herdr_cli_locked "$@"
      }
      fm_backend_herdr_kill fmtest:w2:p2
    ' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "an emptying non-focused kill should stay best-effort: $out"
  [ "$(cat "$lock_log")" = "$(printf 'acquire\nrelease')" ] \
    || fail "the generic kill did not hold one presentation lock across its complete mutation: $(cat "$lock_log")"
  [ ! -e "$lock_held" ] || fail "the generic kill retained its presentation lock"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "an emptying non-focused kill used the focus-unsafe explicit close"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' "an emptying non-focused kill moved focus"
  pass "fm_backend_herdr_kill: one session lock covers the focus-safe emptying removal"
}

test_kill_focused_workspace_stays_plain_close() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/kill-focused"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":true}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/5.out"
  sleep 300 & bgpid=$!
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_presentation_session_lock_path() { printf "/tmp/fm-herdr-test-lock"; }
      fm_lock_try_acquire() { return 0; }
      fm_lock_release() { return 0; }
      fm_backend_herdr_kill fmtest:w2:p2
    ' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a focused-workspace kill should stay best-effort: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw2:p2' "a focused-workspace kill did not use the plain close"
  assert_not_contains "$(cat "$log")" $'pane\x1fprocess-info' "a focused-workspace kill ran the idle-shell proof"
  kill -0 "$bgpid" 2>/dev/null || fail "a focused-workspace kill signaled the pane's shell"
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  pass "fm_backend_herdr_kill: killing the focused workspace's tab keeps the legitimate plain close"
}

test_kill_refuses_when_presentation_lock_is_unavailable() {
  local dir mode out status attempts
  dir="$TMP_ROOT/kill-lock-refusal"; mkdir -p "$dir"
  for mode in unresolved contended; do
    : > "$dir/cli.log"
    : > "$dir/attempts"
    out=$(ROOT="$ROOT" MODE="$mode" CLI_LOG="$dir/cli.log" ATTEMPTS="$dir/attempts" bash -c '
      . "$ROOT/bin/backends/herdr.sh"
      fm_backend_herdr_target_ready() { fm_backend_herdr_parse_target "$1"; }
      fm_backend_herdr_presentation_session_lock_path() {
        [ "$MODE" = contended ] || return 1
        printf "/tmp/fm-herdr-contended-test-lock"
      }
      fm_lock_try_acquire() {
        printf "x\n" >> "$ATTEMPTS"
        return 1
      }
      fm_backend_herdr_cli() {
        printf "%s\n" "$*" >> "$CLI_LOG"
        return 0
      }
      sleep() { :; }
      fm_backend_herdr_kill fmtest:w2:p2
    ' 2>&1)
    status=$?
    [ "$status" -eq 0 ] || fail "$mode presentation lock refusal changed best-effort kill status: $status"
    [ ! -s "$dir/cli.log" ] || fail "$mode presentation lock refusal still mutated Herdr: $(cat "$dir/cli.log")"
    assert_contains "$out" "refusing an unlocked pane close" \
      "$mode presentation lock refusal did not report the deferred close"
    attempts=$(wc -l < "$dir/attempts" | tr -d ' ')
    if [ "$mode" = contended ]; then
      [ "$attempts" = 50 ] || fail "contended presentation lock did not use the bounded wait: $attempts attempts"
    else
      [ "$attempts" = 0 ] || fail "unresolved presentation lock path attempted acquisition: $attempts"
    fi
  done
  pass "fm_backend_herdr_kill: unavailable session locks defer every pane close"
}

test_endpoint_confirmed_gone_gates_on_structured_presence() {
  local out
  out=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_cli() { printf "%s\n" "$FM_FAKE_PRESENCE_RESPONSE"; return "${FM_FAKE_PRESENCE_STATUS:-0}"; }
    check() {  # <label> <response> <status> <mode> <expected-rc>
      FM_FAKE_PRESENCE_RESPONSE=$2 FM_FAKE_PRESENCE_STATUS=$3
      rc=0
      fm_backend_herdr_endpoint_confirmed_gone fmtest:w2:p2 "$4" || rc=$?
      [ "$rc" = "$5" ] || printf "MISMATCH %s: rc=%s expected=%s\n" "$1" "$rc" "$5"
    }
    check present-default "{\"result\":{\"pane\":{\"pane_id\":\"w2:p2\"}}}" 0 "" 1
    check present-strict "{\"result\":{\"pane\":{\"pane_id\":\"w2:p2\"}}}" 0 strict 1
    check notfound-default "{\"error\":{\"code\":\"pane_not_found\"}}" 1 "" 0
    check notfound-strict "{\"error\":{\"code\":\"pane_not_found\"}}" 1 strict 0
    check unknown-default "" 1 "" 1
    check unknown-strict "" 1 strict 1
    check othererror-default "{\"error\":{\"code\":\"internal\"}}" 1 "" 1
    check othererror-strict "{\"error\":{\"code\":\"internal\"}}" 1 strict 1
    # Missing or malformed endpoint identity is ambiguity, never proof of a
    # gone pane: it must refuse record removal.
    rc=0
    fm_backend_herdr_endpoint_confirmed_gone malformed-target strict || rc=$?
    [ "$rc" = 1 ] || printf "MISMATCH malformed-target: rc=%s expected=1\n" "$rc"
    rc=0
    fm_backend_herdr_endpoint_confirmed_gone "" || rc=$?
    [ "$rc" = 1 ] || printf "MISMATCH empty-target: rc=%s expected=1\n" "$rc"
  ' "$ROOT" 2>&1)
  [ -z "$out" ] || fail "endpoint confirmed-gone gate matrix mismatch: $out"
  pass "endpoint confirmed-gone: only structured not-found permits record removal and ambiguous identity refuses"
}

test_projection_seeded_prune_refuses_active_tab() {
  local dir log resp fb out status
  dir="$TMP_ROOT/projection-seeded-focus-active-refusal"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","label":"1","workspace_id":"w9","focused":true},{"tab_id":"w9:t2","label":"fm-task","workspace_id":"w9","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w9:p1","tab_id":"w9:t1"},{"pane_id":"w9:p2","tab_id":"w9:t2"}]}}' > "$resp/2.out"
  printf '%s\n' '{"error":{"code":"agent_not_found"}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w9","active_tab_id":"w9:t1","focused":true}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","focused":true},{"tab_id":"w9:t2","focused":false}]}}' > "$resp/5.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w9:p1","tab_id":"w9:t1","workspace_id":"w9"}}}' > "$resp/6.out"
  cp "$resp/1.out" "$resp/7.out"
  cp "$resp/4.out" "$resp/8.out"
  cp "$resp/5.out" "$resp/9.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_FAKE_HERDR_FOREGROUND_REASON=cleared \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_prune_seeded_default_tab fmtest w9 w9:t1 focus-preserving' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "projected seeded pruning must refuse the active tab"
  assert_contains "$out" "target is the captain's active tab" \
    "projected seeded prune did not explain its active-tab refusal"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' \
    "projected seeded prune closed the captain's active tab"
  pass "herdr presentation focus: projected seeded pruning refuses the active tab"
}

test_projection_label_builder_uses_corner_and_strips_owner_prefixes() {
  local primary secondmate token
  token='AbCdEfGhIjKlMnOpQrStUv'
  [ "${#token}" -eq 22 ] || fail "fixture token must be 22 characters"
  primary=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_workspace_label task-p2 '"$token" "$ROOT")
  [ "$primary" = "└ task-p2 · p:$token" ] \
    || fail "primary child label was wrong: $primary"
  secondmate=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_workspace_label secondmate-child-demo '"$token" "$ROOT")
  [ "$secondmate" = "└ secondmate-child-demo · p:$token" ] \
    || fail "secondmate child label was wrong: $secondmate"
  primary=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_workspace_label firstmate/task-p2 '"$token" "$ROOT")
  [ "$primary" = "└ task-p2 · p:$token" ] \
    || fail "firstmate/ owner prefix was not stripped: $primary"
  secondmate=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_workspace_label 2ndmate-fmdev-f2/child '"$token" "$ROOT")
  [ "$secondmate" = "└ child · p:$token" ] \
    || fail "2ndmate owner prefix was not stripped: $secondmate"
  primary=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_workspace_label fm-task-p2 '"$token" "$ROOT")
  [ "$primary" = "└ task-p2 · p:$token" ] \
    || fail "presentation fm- owner prefix was not stripped: $primary"
  case "$primary" in $'└ '*) ;; *) fail "label must start with U+2514 and one space" ;; esac
  pass "herdr presentation labels: └ concise-task · p:<full-token> for primary and secondmate children"
}

test_projection_order_moves_only_exact_new_workspace_and_preserves_relative_order() {
  local dir log resp fb mover mover_log out status
  dir="$TMP_ROOT/projection-order"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; mover_log="$dir/mover.log"
  : > "$log"; : > "$mover_log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":false},{"workspace_id":"w2","label":"firstmate/old · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w3","label":"2ndmate-alpha","focused":false},{"workspace_id":"w4","label":"2ndmate-bravo","focused":true},{"workspace_id":"w5","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016 # $defs is a literal JSON Schema key.
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FM_FAKE_MOVER_LOG"
printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w1","label":"firstmate","focused":false},{"workspace_id":"w2","label":"firstmate/old · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w5","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe","focused":false},{"workspace_id":"w3","label":"2ndmate-alpha","focused":false},{"workspace_id":"w4","label":"2ndmate-bravo","focused":true}]}}'
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_LOG="$mover_log" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "w4\tw4:t2"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_order_best_effort fmtest w5 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "best-effort projection ordering must not fail the spawn"
  [ -z "$out" ] || fail "successful projection ordering emitted a warning: $out"
  [ "$(cat "$mover_log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w5"$'\t'"2" ] \
    || fail "projection ordering did not move only the exact new response id to the owning-parent append index"
  assert_not_contains "$(cat "$log")" $'workspace\x1fclose' "projection ordering called workspace close"
  assert_not_contains "$(cat "$log")" $'session\x1fdelete' "projection ordering called session delete"
  assert_not_contains "$(cat "$log")" $'workspace\x1frename' "projection ordering called a label-based workspace mutation"
  pass "herdr presentation ordering: exact new workspace appends to the primary block while focus and relative orders stay stable"
}

# run_group_order_case <name> <group-key> <children-json-array>: one projected
# create under parent w1 with the given existing children, then the new w9
# last; the mover answers with w9 at the requested index. Prints the mover's
# requested index, or nothing when no move was attempted.
run_group_order_case() {
  local name=$1 key=$2 children=$3 dir log resp fb mover mover_log out status
  dir="$TMP_ROOT/projection-order-group-$name"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; mover_log="$dir/mover.log"
  : > "$log"; : > "$mover_log"
  jq -cn --argjson children "$children" '
    {result: {workspaces: ([{workspace_id: "w1", label: "firstmate"}] + $children
      + [{workspace_id: "w9", label: "└ new · p:ZyXwVuTsRqPoNmLkJiHgFe"}])}}' > "$dir/base.json"
  cp "$dir/base.json" "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.9.3","protocol":22},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016 # $defs is a literal JSON Schema key.
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$3" >> "$FM_FAKE_MOVER_LOG"
jq -c --argjson at "$3" '
  .result.workspaces as $w
  | ([$w[] | select(.workspace_id != "w9")]) as $rest
  | {id: "fm-workspace-move", result: {type: "workspace_list",
      workspaces: ($rest[0:$at] + [$w[-1]] + $rest[$at:])}}' "$FM_FAKE_BASE"
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_LOG="$mover_log" FM_FAKE_BASE="$dir/base.json" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "w1\tw1:t1"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_order_best_effort fmtest w9 firstmate w1 "$1"' "$ROOT" "$key" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "group ordering $name must not fail the spawn: $out"
  [ -z "$out" ] || fail "group ordering $name emitted a warning: $out"
  assert_not_contains "$(cat "$log")" $'workspace\x1fclose' "group ordering $name called workspace close"
  assert_not_contains "$(cat "$log")" $'workspace\x1frename' "group ordering $name renamed a workspace"
  cat "$mover_log"
}

test_projection_order_group_key_places_new_task_inside_its_group() {
  local tagged at
  tagged='[{"workspace_id":"w2","label":"└ a · p:AbCdEfGhIjKlMnOpQrStU1","tokens":{"fm_group_order":"001.Web"}},
           {"workspace_id":"w3","label":"└ b · p:AbCdEfGhIjKlMnOpQrStU2","tokens":{"fm_group_order":"001.Web"}},
           {"workspace_id":"w4","label":"└ c · p:AbCdEfGhIjKlMnOpQrStU3","tokens":{"fm_group_order":"003.Other"}},
           {"workspace_id":"wH","label":"captain-notes"}]'
  at=$(run_group_order_case middle 002.Backend "$tagged")
  [ "$at" = 3 ] || fail "a new group-2 task must land after the group-1 children and before group 3, got index: $at"
  at=$(run_group_order_case same-group 001.Web "$tagged")
  [ "$at" = 3 ] || fail "a new task must land at the end of its own group, got index: $at"
  at=$(run_group_order_case first 000.Alpha "$tagged")
  [ "$at" = 1 ] || fail "a new task sorting first must land at the block start, got index: $at"
  at=$(run_group_order_case last 999.Zed "$tagged")
  [ "$at" = 4 ] || fail "a new task sorting last must land at the block end, before a foreign workspace, got index: $at"
  at=$(run_group_order_case untagged 001.Web '[{"workspace_id":"w2","label":"└ a · p:AbCdEfGhIjKlMnOpQrStU1","tokens":{"fm_group_order":"003.Other"}},
           {"workspace_id":"w3","label":"└ b · p:AbCdEfGhIjKlMnOpQrStU2"},
           {"workspace_id":"w4","label":"└ c · p:AbCdEfGhIjKlMnOpQrStU3","tokens":{"fm_group_order":"003.Other"}}]')
  [ "$at" = 3 ] || fail "an untagged child must never end up behind a new task, got index: $at"
  at=$(run_group_order_case no-key '' "$tagged")
  [ "$at" = 4 ] || fail "without a group key the block-end placement must be unchanged, got index: $at"
  pass "herdr presentation ordering: a group key places only the new workspace inside its group, untagged children stay ahead"
}

test_projection_order_secondmate_parent_block() {
  local dir log resp fb mover mover_log out status
  dir="$TMP_ROOT/projection-order-secondmate"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; mover_log="$dir/mover.log"
  : > "$log"; : > "$mover_log"
  # firstmate, primary child, 2ndmate-A, A-child legacy, 2ndmate-B, human, NEW for A
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"└ primary · p:AbCdEfGhIjKlMnOpQrStUv"},{"workspace_id":"w3","label":"2ndmate-alpha"},{"workspace_id":"w4","label":"2ndmate-alpha/old · p:AbCdEfGhIjKlMnOpQrStU1"},{"workspace_id":"w5","label":"2ndmate-bravo"},{"workspace_id":"wH","label":"human-notes"},{"workspace_id":"w6","label":"└ new-a · p:ZyXwVuTsRqPoNmLkJiHgFe"}]}}' > "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FM_FAKE_MOVER_LOG"
printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"└ primary · p:AbCdEfGhIjKlMnOpQrStUv"},{"workspace_id":"w3","label":"2ndmate-alpha"},{"workspace_id":"w4","label":"2ndmate-alpha/old · p:AbCdEfGhIjKlMnOpQrStU1"},{"workspace_id":"w6","label":"└ new-a · p:ZyXwVuTsRqPoNmLkJiHgFe"},{"workspace_id":"w5","label":"2ndmate-bravo"},{"workspace_id":"wH","label":"human-notes"}]}}'
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_LOG="$mover_log" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "w5\tw5:t1"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_order_best_effort fmtest w6 2ndmate-alpha' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "secondmate parent ordering must not fail the spawn: $out"
  [ -z "$out" ] || fail "successful secondmate ordering emitted a warning: $out"
  [ "$(cat "$mover_log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w6"$'\t'"4" ] \
    || fail "secondmate child was not inserted after its parent block: $(cat "$mover_log")"
  assert_not_contains "$(cat "$log")" $'workspace\x1frename' "secondmate ordering renamed a legacy child"
  pass "herdr presentation ordering: secondmate children append under their owning parent block"
}

test_projection_order_foreign_legacy_child_is_read_only() {
  local dir log resp fb mover out status
  dir="$TMP_ROOT/projection-order-foreign-legacy"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"2ndmate-alpha"},{"workspace_id":"w3","label":"2ndmate-bravo/foreign · p:AbCdEfGhIjKlMnOpQrStUv"},{"workspace_id":"w4","label":"└ new-alpha · p:ZyXwVuTsRqPoNmLkJiHgFe"}]}}' > "$resp/1.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w4 2ndmate-alpha' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "foreign legacy ordering must not fail the spawn"
  assert_contains "$out" "ambiguous workspace layout" "foreign legacy child did not warn"
  [ ! -e "$dir/called" ] || fail "foreign legacy child attempted workspace.move"
  assert_not_contains "$(cat "$log")" $'workspace\x1fclose' "foreign legacy layout triggered workspace cleanup"
  assert_not_contains "$(cat "$log")" $'session\x1fdelete' "foreign legacy layout triggered session cleanup"
  assert_not_contains "$(cat "$log")" $'workspace\x1frename' "foreign legacy layout triggered workspace rename"
  pass "herdr presentation ordering: a foreign legacy child is warning-only and read-only"
}

test_projection_order_allows_intervening_parent_child_block() {
  local dir log resp fb mover mover_log out status
  dir="$TMP_ROOT/projection-order-intervening-parent"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; mover_log="$dir/mover.log"
  : > "$log"; : > "$mover_log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"firstmate/old · p:AbCdEfGhIjKlMnOpQrStUv"},{"workspace_id":"w3","label":"2ndmate-alpha"},{"workspace_id":"w4","label":"2ndmate-bravo"},{"workspace_id":"w5","label":"└ bravo-child · p:QqWwEeRrTtYyUuIiOoPpAa"},{"workspace_id":"w6","label":"└ new-first · p:ZyXwVuTsRqPoNmLkJiHgFe"}]}}' > "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FM_FAKE_MOVER_LOG"
printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"firstmate/old · p:AbCdEfGhIjKlMnOpQrStUv"},{"workspace_id":"w6","label":"└ new-first · p:ZyXwVuTsRqPoNmLkJiHgFe"},{"workspace_id":"w3","label":"2ndmate-alpha"},{"workspace_id":"w4","label":"2ndmate-bravo"},{"workspace_id":"w5","label":"└ bravo-child · p:QqWwEeRrTtYyUuIiOoPpAa"}]}}'
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_LOG="$mover_log" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "w4\tw4:t1"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_order_best_effort fmtest w6 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "intervening parent ordering must not fail the spawn: $out"
  [ -z "$out" ] || fail "legitimate intervening parent ordering emitted a warning: $out"
  [ "$(cat "$mover_log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w6"$'\t'"2" ] \
    || fail "intervening parent block prevented the owning-parent insertion: $(cat "$mover_log")"
  pass "herdr presentation ordering: intervening parent child blocks remain traversable"
}

test_projection_order_human_spaces_never_move_targets() {
  local dir log resp fb mover mover_log out status
  dir="$TMP_ROOT/projection-order-human"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; mover_log="$dir/mover.log"
  : > "$log"; : > "$mover_log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wH1","label":"notes"},{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"wH2","label":"scratch"},{"workspace_id":"w2","label":"2ndmate-alpha"},{"workspace_id":"w3","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe"}]}}' > "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FM_FAKE_MOVER_LOG"
printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"wH1","label":"notes"},{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w3","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe"},{"workspace_id":"wH2","label":"scratch"},{"workspace_id":"w2","label":"2ndmate-alpha"}]}}'
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_LOG="$mover_log" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "w2\tw2:t1"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_order_best_effort fmtest w3 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "human-interleaved ordering must not fail: $out"
  [ "$(cat "$mover_log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w3"$'\t'"2" ] \
    || fail "human spaces changed the move target or insert index: $(cat "$mover_log")"
  pass "herdr presentation ordering: only the exact new id moves; human spaces keep relative order"
}

test_projection_order_failure_warns_without_cleanup_or_spawn_failure() {
  local dir log resp fb mover out status
  dir="$TMP_ROOT/projection-order-failure"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true},{"workspace_id":"w2","label":"2ndmate-alpha","focused":false},{"workspace_id":"w3","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016 # $defs is a literal JSON Schema key.
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
exit 9
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "w1\tw1:t1"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_order_best_effort fmtest w3 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a workspace.move failure must not fail the projected spawn"
  assert_contains "$out" "workspace move failed or had an ambiguous response" \
    "workspace.move failure did not report the best-effort warning"
  assert_not_contains "$(cat "$log")" $'workspace\x1fclose' "workspace.move failure triggered workspace cleanup"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "workspace.move failure triggered pane cleanup"
  assert_not_contains "$(cat "$log")" $'session\x1fdelete' "workspace.move failure triggered session cleanup"
  pass "herdr presentation ordering: move failure warns, returns success, and grants no cleanup authority"
}

test_projection_order_ambiguous_existing_block_is_read_only() {
  local dir log resp fb mover out status
  dir="$TMP_ROOT/projection-order-ambiguous"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  # Detached legacy child after the next parent breaks the contiguous block.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true},{"workspace_id":"w2","label":"2ndmate-alpha","focused":false},{"workspace_id":"w3","label":"firstmate/old · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w4","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe","focused":false}]}}' > "$resp/1.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w4 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "ambiguous projection ordering must not fail the spawn"
  assert_contains "$out" "ambiguous workspace layout" "ambiguous projection layout did not warn"
  [ ! -e "$dir/called" ] || fail "ambiguous projection layout attempted workspace.move"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" = 1 ] \
    || fail "ambiguous projection ordering did more than one read-only workspace list"
  pass "herdr presentation ordering: an ambiguous existing worker block is warning-only and read-only"
}

test_projection_order_anchors_the_parent_by_exact_id() {
  local dir log resp fb mover layout out status
  layout='{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":false},{"workspace_id":"w7","label":"firstmate","focused":false},{"workspace_id":"wH","label":"human-notes","focused":false},{"workspace_id":"w8","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe","focused":false}]}}'

  # Without the exact parent id, two same-labeled parents make the whole layout
  # ambiguous and ordering steps aside.
  dir="$TMP_ROOT/projection-order-dup-label"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' "$layout" > "$resp/1.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w8 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "ambiguous projection ordering must not fail the spawn"
  assert_contains "$out" "ambiguous workspace layout" "a duplicated parent label should make label-anchored ordering step aside"
  [ ! -e "$dir/called" ] || fail "ambiguous parent label attempted workspace.move"

  # With the launcher's exact parent workspace id, the same layout is no longer
  # ambiguous: ordering gets past parent selection and stops later, on this
  # fake's protocol, having still moved nothing.
  dir="$TMP_ROOT/projection-order-exact-parent"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' "$layout" > "$resp/1.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w8 firstmate w7' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "exact-parent projection ordering must not fail the spawn"
  assert_not_contains "$out" "ambiguous workspace layout" "the exact parent id should have resolved the duplicated label"
  assert_contains "$out" "protocol" "exact-parent ordering did not reach its protocol gate"
  [ ! -e "$dir/called" ] || fail "exact-parent ordering attempted workspace.move below the required protocol"
  pass "herdr presentation ordering: the launcher's exact parent workspace id disambiguates a duplicated home label without moving anything"
}

test_projection_order_foreign_new_child_before_parent_is_read_only() {
  local dir log resp fb mover out status
  dir="$TMP_ROOT/projection-order-foreign-new"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true},{"workspace_id":"wH","label":"human-notes","focused":false},{"workspace_id":"w2","label":"└ foreign · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w3","label":"2ndmate-alpha","focused":false},{"workspace_id":"w4","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe","focused":false}]}}' > "$resp/1.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w4 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "foreign new-child ordering must not fail the spawn"
  assert_contains "$out" "ambiguous workspace layout" "foreign new child before its parent did not warn"
  [ ! -e "$dir/called" ] || fail "foreign new child before its parent attempted workspace.move"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" = 1 ] \
    || fail "foreign new-child ordering did more than one read-only workspace list"
  pass "herdr presentation ordering: a foreign new-format child is warning-only and read-only"
}

test_projection_order_missing_parent_is_read_only() {
  local dir log resp fb mover out status
  dir="$TMP_ROOT/projection-order-missing-parent"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe"}]}}' > "$resp/1.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w2 2ndmate-missing' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "missing parent must not fail the spawn"
  assert_contains "$out" "ambiguous workspace layout" "missing parent did not warn"
  [ ! -e "$dir/called" ] || fail "missing parent attempted workspace.move"
  pass "herdr presentation ordering: missing owning parent is warning-only and read-only"
}

test_presentation_session_lock_path_is_shared_across_homes() {
  local dir log resp fb path_a path_b path_other path_tmp path_private
  dir="$TMP_ROOT/presentation-session-lock"; mkdir -p "$dir/responses" "$dir/sockdir"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  : > "$dir/sockdir/fmtest.sock"
  printf '%s\n' "{\"sessions\":[{\"name\":\"fmtest\",\"running\":true,\"socket_path\":\"$dir/sockdir/fmtest.sock\"}]}" > "$resp/1.out"
  printf '%s\n' "{\"sessions\":[{\"name\":\"fmtest\",\"running\":true,\"socket_path\":\"$dir/sockdir/fmtest.sock\"}]}" > "$resp/2.out"
  printf '%s\n' "{\"sessions\":[{\"name\":\"other\",\"running\":true,\"socket_path\":\"$dir/sockdir/other.sock\"}]}" > "$resp/3.out"
  : > "$dir/sockdir/other.sock"
  fb=$(make_herdr_fakebin "$dir")
  path_a=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path fmtest' "$ROOT") \
    || fail "session lock path resolution failed for home A"
  path_b=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path fmtest' "$ROOT") \
    || fail "session lock path resolution failed for home B"
  [ "$path_a" = "$path_b" ] || fail "same session/socket must resolve one shared lock path"
  case "$path_a" in
    "/tmp/firstmate-herdr-presentation-$(id -u)"/order-*.lock) ;;
    *) fail "session lock path must use this account's namespace: $path_a" ;;
  esac
  case "$path_a" in
    */state/*) fail "session lock path must not live under a home state directory: $path_a" ;;
  esac
  path_other=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path other' "$ROOT") \
    || fail "session lock path resolution failed for a different session"
  [ "$path_other" != "$path_a" ] || fail "different sessions must not share one lock path"
  # Symlink parents such as /tmp -> /private/tmp must not split the lock identity.
  if [ -L /tmp ] || [ "$(cd /tmp && pwd -P)" != /tmp ]; then
    : > /tmp/fm-herdr-lock-canon-$$.sock
    printf '%s\n' '{"sessions":[{"name":"canon","running":true,"socket_path":"/tmp/fm-herdr-lock-canon-'"$$"'.sock"}]}' > "$resp/4.out"
    printf '%s\n' "{\"sessions\":[{\"name\":\"canon\",\"running\":true,\"socket_path\":\"$(cd /tmp && pwd -P)/fm-herdr-lock-canon-$$.sock\"}]}" > "$resp/5.out"
    path_tmp=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path canon' "$ROOT") \
      || fail "lock path with /tmp socket failed"
    path_private=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path canon' "$ROOT") \
      || fail "lock path with canonical socket failed"
    rm -f /tmp/fm-herdr-lock-canon-$$.sock
    [ "$path_tmp" = "$path_private" ] \
      || fail "symlink parent socket paths must resolve one lock: $path_tmp vs $path_private"
  fi
  pass "herdr presentation lock: one path per session/socket across homes"
}

test_presentation_session_lock_path_rejects_malformed_socket() {
  local dir log resp fb path status
  dir="$TMP_ROOT/presentation-malformed-socket"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":null}]}' > "$resp/1.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true}]}' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  path=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path fmtest' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "null socket_path must refuse the presentation lock path"
  [ -z "$path" ] || fail "null socket_path returned a lock path: $path"
  case "$path" in *null*) fail "null socket_path leaked into a lock path: $path" ;; esac
  path=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path fmtest' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "missing socket_path must refuse the presentation lock path"
  [ -z "$path" ] || fail "missing socket_path returned a lock path: $path"
  pass "herdr presentation lock: null and missing socket paths fail closed"
}

test_projection_order_rejects_malformed_socket() {
  local dir log resp fb mover out status
  dir="$TMP_ROOT/projection-order-malformed-socket"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"wH","label":"2ndmate-alpha"},{"workspace_id":"w2","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe"}]}}' > "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":null}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w2 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "malformed ordering socket must not fail the spawn"
  assert_contains "$out" "ambiguous named session socket" "malformed ordering socket did not warn"
  [ ! -e "$dir/called" ] || fail "malformed ordering socket attempted workspace.move"
  pass "herdr presentation ordering: malformed socket metadata is warning-only and read-only"
}

test_projection_reclaim_refusal_matrix_is_non_mutating() {
  local dir state home other_home home_real journal legacy token label out mutation_log
  dir="$TMP_ROOT/projection-reclaim-refusals"; state="$dir/state"; home="$dir/home"; other_home="$dir/other-home"
  mkdir -p "$state" "$home" "$other_home"
  home_real=$(cd "$home" && pwd -P)
  token=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    token=$(fm_backend_herdr_projection_journal_create "$1" refusal-r1) || exit 1
    label=$(fm_backend_herdr_projection_workspace_label refusal-r1 "$token")
    fm_backend_herdr_projection_journal_bind \
      "$1/refusal-r1.herdr-presentation" refusal-r1 "$2" fmtest \
      w2 w2:t2 w2:p2 w1 firstmate "$label" fm-refusal-r1 || exit 1
    printf "%s" "$token"
  ' "$ROOT" "$state" "$home_real") || fail "could not create reclaim refusal fixture"
  journal="$state/refusal-r1.herdr-presentation"
  label="└ refusal-r1 · p:$token"
  mkdir -p "$state/legacy"
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_journal_create "$1" refusal-r1 >/dev/null' \
    "$ROOT" "$state/legacy" || fail "could not create legacy reclaim fixture"
  legacy="$state/legacy/refusal-r1.herdr-presentation"
  mutation_log="$dir/mutations.log"; : > "$mutation_log"
  out=$(ROOT="$ROOT" JOURNAL="$journal" LEGACY="$legacy" HOME_A="$home" HOME_B="$other_home" MUTATIONS="$mutation_log" \
    bash -c '
      . "$ROOT/bin/backends/herdr.sh"
      fm_backend_herdr_cli() { printf "%s\n" "$*" >> "$MUTATIONS"; return 1; }
      run_case() {
        mode=$1; journal=$2; home=$3
        fm_backend_herdr_projection_live_binding_matches() {
          [ "$mode" != ambiguous ]
        }
        fm_backend_herdr_pane_agent_state() {
          case "$mode" in
            live) printf live ;;
            unknown) printf unknown ;;
            *) printf no-agent ;;
          esac
        }
        fm_backend_herdr_projection_focus_snapshot() {
          [ "$mode" != focus-unknown ] || return 1
          printf "w1\tw1:t1"
        }
        set +e
        fm_backend_herdr_projection_reclaim_task \
          fmtest "$journal" refusal-r1 "$home" w2 w2:t2 w2:p2 firstmate fm-refusal-r1 /tmp/project \
          >/dev/null 2>&1
        rc=$?
        set -e
        printf "%s:%s\n" "$mode" "$rc"
      }
      run_case legacy "$LEGACY" "$HOME_A"
      run_case cross-home "$JOURNAL" "$HOME_B"
      run_case ambiguous "$JOURNAL" "$HOME_A"
      run_case live "$JOURNAL" "$HOME_A"
      run_case unknown "$JOURNAL" "$HOME_A"
      run_case focus-unknown "$JOURNAL" "$HOME_A"
    ')
  [ "$out" = $'legacy:2\ncross-home:2\nambiguous:2\nlive:1\nunknown:1\nfocus-unknown:2' ] \
    || fail "reclaim refusal matrix returned wrong decisions: $out"
  [ ! -s "$mutation_log" ] \
    || fail "legacy, cross-home, ambiguous, live/unknown, or focus-unknown refusal mutated Herdr: $(cat "$mutation_log")"
  [ "$(sed -n 's/^workspace_label=//p' "$journal")" = "$label" ] \
    || fail "reclaim refusal matrix rewrote the bound workspace label"
  pass "herdr presentation reclaim: legacy, cross-home, ambiguous, live/unknown, and focus-unknown cases refuse without mutation"
}

test_projection_reclaim_replaces_only_exact_husk_and_advances_binding() {
  local dir state home home_real log resp fb journal token label out calls create_line close_line agent_line boundary_mutations
  dir="$TMP_ROOT/projection-reclaim-exact"; state="$dir/state"; home="$dir/home"
  mkdir -p "$dir/responses" "$state" "$home"
  home_real=$(cd "$home" && pwd -P)
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  token=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    token=$(fm_backend_herdr_projection_journal_create "$1" fm-hibit-r1) || exit 1
    label=$(fm_backend_herdr_projection_workspace_label fm-hibit-r1 "$token")
    fm_backend_herdr_projection_journal_bind \
      "$1/fm-hibit-r1.herdr-presentation" fm-hibit-r1 "$2" fmtest \
      w2 w2:t2 w2:p2 w1 firstmate "$label" fm-fm-hibit-r1 || exit 1
    printf "%s" "$token"
  ' "$ROOT" "$state" "$home_real") || fail "could not create exact reclaim journal fixture"
  journal="$state/fm-hibit-r1.herdr-presentation"
  label="└ hibit-r1 · p:$token"
  printf '%s\n' "{\"result\":{\"workspaces\":[{\"workspace_id\":\"w0\",\"label\":\"firstmate\",\"focused\":false,\"active_tab_id\":\"w0:t1\"},{\"workspace_id\":\"w1\",\"label\":\"firstmate\",\"focused\":true,\"active_tab_id\":\"w1:t1\"},{\"workspace_id\":\"w2\",\"label\":\"$label\",\"focused\":false,\"active_tab_id\":\"w2:t2\"}]}}" > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","label":"fm-fm-hibit-r1"}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/4.out"
  printf '%s\n' '{"error":{"code":"agent_not_found"}}' > "$resp/5.out"
  printf '%s\n' "{\"result\":{\"workspaces\":[{\"workspace_id\":\"w1\",\"label\":\"firstmate\",\"focused\":true,\"active_tab_id\":\"w1:t1\"},{\"workspace_id\":\"w2\",\"label\":\"$label\",\"focused\":false,\"active_tab_id\":\"w2:t2\"}]}}" > "$resp/6.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/7.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t3"},"root_pane":{"pane_id":"w2:p3"}}}' > "$resp/8.out"
  cp "$resp/6.out" "$resp/9.out"
  cp "$resp/7.out" "$resp/10.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t3","workspace_id":"w2"}}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p3","tab_id":"w2:t3","workspace_id":"w2"}}}' > "$resp/12.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/13.out"
  printf '%s\n' '{"error":{"code":"agent_not_found"}}' > "$resp/14.out"
  cp "$resp/6.out" "$resp/15.out"
  cp "$resp/7.out" "$resp/16.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/17.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/18.out"
  printf '%s\n' '{"error":{"code":"agent_not_found"}}' > "$resp/19.out"
  # The emptying-close plan sees the replacement tab alongside the old husk
  # tab, so the husk close stays plain.
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","label":"fm-fm-hibit-r1"},{"tab_id":"w2:t3","label":"fm-fm-hibit-r1"}]}}' > "$resp/20.out"
  : > "$resp/21.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/22.out"
  cp "$resp/6.out" "$resp/23.out"
  cp "$resp/7.out" "$resp/24.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/25.out"
  cp "$resp/1.out" "$resp/26.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t3","label":"fm-fm-hibit-r1"}]}}' > "$resp/27.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p3","tab_id":"w2:t3"}]}}' > "$resp/28.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_projection_reclaim_task \
        fmtest "$1" fm-hibit-r1 "$2" w2 w2:t2 fmtest:w2:p2 firstmate fm-fm-hibit-r1 /tmp/project || exit 1
      printf "%s %s" "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" "$FM_BACKEND_HERDR_PROJECTION_PANE_ID"
    ' "$ROOT" "$journal" "$home") || fail "exact agent-free projection reclaim failed"
  [ "$out" = "w2:t3 w2:p3" ] || fail "reclaim did not return exact replacement ids: $out"
  [ "$(sed -n 's/^tab_id=//p' "$journal")" = w2:t3 ] \
    && [ "$(sed -n 's/^pane_id=//p' "$journal")" = w2:p3 ] \
    || fail "reclaim did not advance the journal to the replacement endpoint"
  calls=$(cat "$log")
  create_line=$(grep -n $'tab\x1fcreate\x1f--workspace\x1fw2' "$log" | cut -d: -f1)
  close_line=$(grep -n $'pane\x1fclose\x1fw2:p2' "$log" | cut -d: -f1)
  [ -n "$create_line" ] && [ -n "$close_line" ] && [ "$create_line" -lt "$close_line" ] \
    || fail "reclaim did not create the exact replacement before closing the old husk"
  agent_line=$(grep -n $'agent\x1fget\x1fw2:p2' "$log" | tail -1 | cut -d: -f1)
  [ -n "$agent_line" ] && [ "$agent_line" -lt "$close_line" ] \
    || fail "reclaim did not recheck the old pane agent state before the close"
  boundary_mutations=$(sed -n "$((agent_line + 1)),$((close_line - 1))p" "$log" \
    | grep -Ev $'\x1f(tab\x1flist|pane\x1flist|workspace\x1flist|terminal\x1ftitle\x1fclear)' || true)
  [ -z "$boundary_mutations" ] \
    || fail "reclaim mutated between the old pane agent recheck and the close: $boundary_mutations"
  assert_not_contains "$calls" $'workspace\x1fclose' "reclaim introduced workspace-close authority"
  assert_not_contains "$calls" $'workspace\x1frename' "reclaim renamed the projected workspace"
  assert_not_contains "$calls" $'tab\x1ffocus' "focus-preserving reclaim changed an already-stable focus snapshot"
  assert_not_contains "$calls" $'\x1fw0' "reclaim touched the same-labeled sibling parent"
  pass "herdr presentation reclaim: exact agent-free husk survives duplicate parent labels while its sibling stays untouched"
}

test_projection_recovery_is_read_only_and_refuses_live_duplicate_risk() {
  local dir state log resp fb token journal out status calls
  dir="$TMP_ROOT/projection-recovery"; state="$dir/state"; mkdir -p "$dir/responses" "$state"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  token=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_journal_create "$1" task-p3' "$ROOT" "$state")
  journal="$state/task-p3.herdr-presentation"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate/task-p3 · p:%s"},{"workspace_id":"w2","label":"copy/task-p3 · p:%s"}]}}\n' "$token" "$token" > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p1"}}}\n' > "$resp/3.out"
  printf '{"error":{"code":"agent_not_found"}}\n' > "$resp/4.out"
  printf '{"result":{"panes":[{"pane_id":"w2:p1","tab_id":"w2:t1"}]}}\n' > "$resp/5.out"
  printf '{"result":{"pane":{"pane_id":"w2:p1"}}}\n' > "$resp/6.out"
  printf '{"error":{"code":"agent_not_found"}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_recovery_allows_flat fmtest "$1" task-p3' "$ROOT" "$journal" \
    >/dev/null || fail "agent-free duplicate token matches should allow flat fallback"
  calls=$(cat "$log")
  assert_not_contains "$calls" $'workspace\x1fcreate' "recovery inspection created a workspace"
  assert_not_contains "$calls" $'workspace\x1fclose' "recovery inspection closed a workspace"
  assert_not_contains "$calls" $'tab\x1fcreate' "recovery inspection created a tab"
  assert_not_contains "$calls" $'tab\x1fclose' "recovery inspection closed a tab"
  assert_not_contains "$calls" $'pane\x1fclose' "recovery inspection closed a pane"

  : > "$log"; rm -f "$resp"/*.out "$resp"/*.exit "$resp/.count"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate/task-p3 · p:%s"}]}}\n' "$token" > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p1"}}}\n' > "$resp/3.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  # 5: process-info -> a live harness backs the registration (issue #4115)
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":4242,"foreground_process_group_id":4243,"foreground_processes":[{"pid":4243,"name":"node","argv0":"pi"}]}}}\n' > "$resp/5.out"
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_recovery_allows_flat fmtest "$1" task-p3' "$ROOT" "$journal" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a token match with a live registered agent must refuse duplicate launch"
  assert_contains "$out" "has a live pane" "live duplicate refusal did not explain the risk"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "live duplicate refusal closed a pane"
  pass "herdr presentation recovery: duplicate-token inspection is read-only and live-agent risk refuses fallback"
}
