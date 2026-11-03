#!/usr/bin/env bash
# Suite body for tests/fm-test-run.test.sh: selection, changed-path mapping,
# reference closure, and the real-inventory bounds. Sourced by the wrapper,
# which owns the prelude and the case invocation list. Function definitions
# only: nothing here executes on source.
test_list_all_exact_suite_coverage() {
  local listed expected missing extra f
  listed=$(printf '%s\n' "$ALL_SUITE_LIST" | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh; do
      [ -f "$f" ] || continue
      printf 'tests/%s\n' "$(basename "$f")"
    done | LC_ALL=C sort
  )
  [ -n "$listed" ] || fail "--list --all printed nothing"
  missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  [ -z "$missing" ] || fail "--list --all missing scripts: $missing"
  [ -z "$extra" ] || fail "--list --all unexpected scripts: $extra"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = \
    "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] \
    || fail "--list --all must not duplicate scripts"
  pass "exact suite coverage: --all lists every tests/*.test.sh once"
}

test_family_selection() {
  local listed line
  listed=$PURE_CONTRACT_LIST
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$(printf '%s\n' "$ALL_SUITE_LIST" | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  pass "family selection returns a proper subset of the suite"
}

test_single_script_selection() {
  local listed
  listed=$("$RUNNER" --list tests/fm-lint.test.sh)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "single-script list expected tests/fm-lint.test.sh, got: $listed"
  pass "single-script selection lists exactly that path"
}

test_environment_record_is_compact_safe_and_emitted_once() {
  local out helper_out fakebin tool tmp_root login_home
  tmp_root=$(fm_test_tmproot fm-test-run-env-record)
  export FM_TEST_ENV_SECRET_SENTINEL='do-not-print-this-secret'
  # Keep one small real-subject integration for the metadata assertions.
  # Correlation-token and ancestry coverage remain in their own required suites.
  out=$("$RUNNER" tests/fm-transition-lib.test.sh 2>&1) \
    || fail "real-subject runner integration failed: $out"
  assert_contains "$out" 'FM_TEST_SUMMARY total=1 failed=0' "real subject did not pass: $out"
  case "$out" in
    *FM_TEST_ENV_RECORD\ v=1*) ;;
    *) fail "an executing runner invocation omitted its environment record: $out" ;;
  esac
  [ "$(printf '%s\n' "$out" | grep -c '^FM_TEST_ENV_RECORD v=1$')" -eq 1 ] \
    || fail "the runner must emit exactly one environment record: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^FM_TEST_ENV_RECORD_END$')" -eq 1 ] \
    || fail "the environment record did not have one end marker: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^FM_TEST_BEGIN ')" -eq 1 ] \
    || fail "the fixture test did not execute exactly once: $out"
  [ "$(printf '%s\n' "$out" | awk '/^FM_TEST_ENV_RECORD v=1$/ {record=NR} /^FM_TEST_BEGIN / {begin=NR} END {print (record > 0 && begin > record) ? "yes" : "no"}')" = yes ] \
    || fail "the environment record must precede the first test marker: $out"
  case "$out" in *do-not-print-this-secret*) fail "the environment record leaked a secret sentinel" ;; esac
  for field in '^shell=bash .*flags=.*argv0=' '^runner_login_shell=(yes|no)$' '^path_entries=' '^shell_options=' '^os=.* kernel=.* machine=' '^process_model=.* subreaper=' '^tmpdir_fs=' '^ulimit=' '^tool=bash (path=.* version=.*|absent)$' '^tool=node (path=.* version=.*|absent)$' '^tool=pi (path=.* version=.*|absent)$' '^tool=tasks-axi (path=.* version=.*|absent)$' '^tool=timeout (path=.* version=.*|absent)$' '^tool=git (path=.* version=.*|absent)$' '^tool=herdr (path=.* version=.*|absent)$' '^tool=tmux (path=.* version=.*|absent)$' '^tool=rsync (path=.* version=.*|absent)$' '^tool=no-mistakes (path=.* version=.*|absent)$' '^chrome_startup=(ok|failed|missing)'; do
    printf '%s\n' "$out" | grep -Eq "$field" || fail "environment record omitted $field: $out"
  done

  fakebin=$(fm_fakebin "$tmp_root/env-record-path")
  for tool in tr cut df awk stat uname ps basename head mktemp rm timeout env; do
    local found
    found=$(command -v "$tool")
    [ -n "$found" ] && ln -sf "$found" "$fakebin/$tool"
  done
  ln -sf "$(command -v bash)" "$fakebin/bash"
  helper_out=$(PATH="$fakebin" /bin/bash "$ROOT/bin/fm-test-env-record.sh" 2>&1)
  assert_contains "$helper_out" 'tool=node absent' "a missing tool should be reported as absent: $helper_out"
  assert_contains "$helper_out" 'FM_TEST_ENV_RECORD_END' "a missing tool broke record generation: $helper_out"
  assert_contains "$helper_out" 'tool=pi absent' "a missing pi should be reported as absent: $helper_out"
  assert_contains "$helper_out" "path_entries=$fakebin" "the record omitted the PATH entries: $helper_out"
  printf '#!/bin/sh\nexit 0\n' >"$fakebin/chromium"
  chmod +x "$fakebin/chromium"
  rm -f "$fakebin/timeout"
  helper_out=$(PATH="$fakebin" /bin/bash "$ROOT/bin/fm-test-env-record.sh" 2>&1)
  printf '#!/bin/sh\necho pi 1\n' >"$fakebin/pi"
  chmod +x "$fakebin/pi"
  helper_out=$(PATH="$fakebin" /bin/bash "$ROOT/bin/fm-test-env-record.sh" 2>&1)
  assert_contains "$helper_out" 'version=probe-skipped' "version probes must be skipped when timeout is missing: $helper_out"
  assert_contains "$helper_out" 'tool=timeout absent' "a missing timeout should be reported as absent: $helper_out"
  assert_contains "$helper_out" 'chrome_startup=failed reason=timeout-missing' "a missing timeout must not read as a Chrome fault: $helper_out"
  # Run the login-shell probes with a hermetic HOME and PATH: the record's own
  # tool and Chrome startup fields are asserted above, and a real login profile
  # would otherwise reintroduce the slow real-browser probe into both calls.
  login_home="$tmp_root/env-record-home"
  mkdir -p "$login_home"
  helper_out=$(HOME="$login_home" PATH="$fakebin:/usr/bin:/bin" \
    /bin/bash -lc "/bin/bash '$ROOT/bin/fm-test-env-record.sh'; :" 2>&1)
  assert_contains "$helper_out" 'runner_login_shell=no' "the runner's own non-login bash must be recorded as no: $helper_out"
  helper_out=$(HOME="$login_home" PATH="$fakebin:/usr/bin:/bin" \
    /bin/bash -l "$ROOT/bin/fm-test-env-record.sh" 2>&1)
  assert_contains "$helper_out" 'runner_login_shell=yes' "a login runner bash must be recorded as yes: $helper_out"
  printf '#!/bin/sh\nsleep 30\n' >"$fakebin/node"
  chmod +x "$fakebin/node"
  ln -sf "$(command -v timeout)" "$fakebin/timeout"
  ln -sf "$(command -v sleep)" "$fakebin/sleep"
  helper_out=$(PATH="$fakebin" /bin/bash "$ROOT/bin/fm-test-env-record.sh" 2>&1)
  assert_contains "$helper_out" 'tool=node path=' "the hanging tool was not recorded: $helper_out"
  assert_contains "$helper_out" 'version=timed-out' "a hanging version probe must be bounded and recorded as timed-out: $helper_out"
  unset FM_TEST_ENV_SECRET_SENTINEL
  pass "the runner emits one bounded secret-free environment record and records missing tools safely"
}

test_changed_file_selection_is_conservative() {
  local listed all_count fam_count listed_count
  # A path-mapped pure unit should not expand to --all.
  listed=$PURE_CONTRACT_LIST
  all_count=$(printf '%s\n' "$ALL_SUITE_LIST" | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] || fail "changed-informed pure family still full suite"
  # Directly exercise --changed: empty or partial selection is ok; must not
  # exceed the suite and must never silently become --all by accident.
  listed=$("$RUNNER" --list --changed --base HEAD 2>/dev/null || true)
  if [ -n "$listed" ]; then
    listed_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$listed_count" -le "$all_count" ] || fail "changed selection larger than suite"
  fi
  # A single test path selects only that script (same contract as a
  # tests/*.test.sh change entry in the map).
  listed=$("$RUNNER" --list tests/fm-brief.test.sh)
  [ "$listed" = "tests/fm-brief.test.sh" ] \
    || fail "test-file-only change contract should select one script"
  pass "changed-file selection stays conservative (never silent full suite)"
}

init_changed_fixture_repo() {
  local repo=$1 script
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-brief.test.sh \
    fm-ask-user-authority.test.sh \
    fm-documentation-audiences.test.sh \
    fm-test-isolation-proof.test.sh \
    fm-test-run.test.sh \
    fm-test-fixtures.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-daemon.test.sh \
    fm-harness-adapter-instructions-live-e2e.test.sh \
    fm-harness-adapter-references.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-secondmate-safety.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-pr-merge.test.sh \
    fm-procevent-quota.test.sh \
    fm-quota-choose.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-pi-windows-shell-invocation.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-control-herdr-smoke.test.sh \
    fm-backend-orca.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/fm-control-lib.sh"
  : >"$repo/bin/fm-timeout-lib.sh"
  : >"$repo/bin/fm-procevent-quota.sh"
  : >"$repo/bin/fm-quota-axi-lib.sh"
  : >"$repo/bin/fm-quota-choose.sh"
  : >"$repo/bin/unmapped-source.sh"
  # A shared top-level test fixture read by two suites in different families,
  # beside a tests/ file nothing reads at all.
  : >"$repo/tests/shared-probe-fixture.sh"
  : >"$repo/tests/unread-thing.sh"
  printf '# shared-probe-fixture.sh\n' >>"$repo/tests/fm-pr-merge.test.sh"
  printf '# shared-probe-fixture.sh\n' >>"$repo/tests/fm-secondmate-safety.test.sh"
  # A nested fixture whose consuming suite names only the fixture directory,
  # the shape the tests/fixtures/<dir>/ arm is keyed for.
  mkdir -p "$repo/tests/fixtures/demo"
  : >"$repo/tests/fixtures/demo/demo-fixture.sh"
  printf '# tests/fixtures/demo\n' >>"$repo/tests/fm-backend-orca.test.sh"
  # A shared helper with no curated family of its own, named by exactly ONE
  # script of the expensive real-Herdr family and consumed by one curated
  # watcher script. This is the shape that made a one-line helper change select
  # every real-Herdr E2E.
  : >"$repo/bin/shared-probe-lib.sh"
  printf '# shared-probe-lib.sh\n' >>"$repo/tests/fm-backend-herdr-smoke.test.sh"
  # shellcheck disable=SC2016  # literal fixture text: the reference must reach
  # the file verbatim so the changed-file scan can find it, not expand here.
  printf '. "$ROOT/bin/shared-probe-lib.sh"\n' >"$repo/bin/fm-watch-probe.sh"
  printf '# fm-watch-probe.sh\n' >>"$repo/tests/fm-daemon.test.sh"
  # A real repository reader, unlike a fixture's copy of the same path.
  # shellcheck disable=SC2016
  printf 'ROOT=$(cd "$(dirname "$0")/.." && pwd)\ncat "$ROOT/.agents/skills/example/SKILL.md"\n' >>"$repo/tests/fm-ask-user-authority.test.sh"
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p \
    "$repo/.agents/skills/example" \
    "$repo/.agents/skills/harness-adapters/references/common" \
    "$repo/.claude" "$repo/.pi/extensions" "$repo/docs" "$repo/src"
  : >"$repo/.agents/skills/example/SKILL.md"
  : >"$repo/.agents/skills/harness-adapters/SKILL.md"
  : >"$repo/.agents/skills/harness-adapters/references/common/dispatch.md"
  : >"$repo/.claude/settings.json"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.pi/extensions/lib"
  : >"$repo/.pi/extensions/lib/fm-operational-input.ts"
  : >"$repo/docs/fm-test-isolation-proof.md"
  : >"$repo/CONTRIBUTING.md"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

# Build a repository with a primary checkout and one linked worktree, each
# holding a runnable copy of the runner and a probe suite that records the fact
# that it ran. Untracked copies are enough: the runner resolves its root from
# its own path, and the probe is named explicitly.
init_primary_and_linked_worktree() {
  local repo=$1 linked=$2 tree
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b linked-probe "$linked"
  for tree in "$repo" "$linked"; do
    mkdir -p "$tree/bin" "$tree/tests"
    cp "$RUNNER" "$tree/bin/fm-test-run.sh"
    cp "$ROOT/tests/git-config-helpers.sh" "$tree/tests/"
    chmod +x "$tree/bin/fm-test-run.sh"
    cat >"$tree/tests/probe.test.sh" <<PROBE
#!/usr/bin/env bash
echo "ok - probe suite"
: >"$tree/ran"
PROBE
    chmod +x "$tree/tests/probe.test.sh"
  done
}

# A task worker's isolated placement is checked once, when the task starts.
# Nothing re-checks it, so a worker that later changes directory into the
# repository's primary checkout would run this branch-switching suite in the one
# checkout every linked worktree resolves against. The runner refuses that.
test_task_marker_refuses_the_primary_checkout() {
  local tmp repo linked out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-primary.XXXXXX")
  repo="$tmp/repo"
  linked="$tmp/linked"
  init_primary_and_linked_worktree "$repo" "$linked"

  # Marker set, primary checkout: refuse, name the primary, and run nothing.
  out=$(FM_TASK_ID=probe-task "$repo/bin/fm-test-run.sh" tests/probe.test.sh 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "the runner must refuse the primary checkout under a task marker"; }
  assert_contains "$out" "primary checkout" "refusal did not name the primary checkout"
  assert_contains "$out" "FM_TASK_ID=probe-task" "refusal did not name the task marker"
  assert_contains "$out" "task worktree" "refusal did not point at the task worktree"
  assert_not_contains "$out" "FM_TEST_BEGIN" "the refusal must happen before any suite runs"
  assert_absent "$repo/ran" "the refused run still executed a suite"

  # Marker set, linked worktree: the assigned placement, so the suite runs.
  FM_TASK_ID=probe-task "$linked/bin/fm-test-run.sh" tests/probe.test.sh >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "the runner must still run in a linked task worktree"; }
  assert_present "$linked/ran" "the linked-worktree run did not execute its suite"

  # No marker: a person in their own checkout is unaffected.
  "$repo/bin/fm-test-run.sh" tests/probe.test.sh >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "an unmarked run in the primary checkout must be unchanged"; }
  assert_present "$repo/ran" "the unmarked run did not execute its suite"

  # Inspection executes nothing, so it stays available even in the primary.
  rm -f "$repo/ran"
  out=$(FM_TASK_ID=probe-task "$repo/bin/fm-test-run.sh" --list tests/probe.test.sh 2>&1) \
    || { rm -rf "$tmp"; fail "--list must remain available under a task marker"; }
  [ "$out" = "tests/probe.test.sh" ] \
    || { rm -rf "$tmp"; fail "--list under a task marker printed: $out"; }
  assert_absent "$repo/ran" "--list must not execute a suite"

  rm -rf "$tmp"
  pass "a task marker refuses execution in the primary checkout and leaves worktrees and inspection alone"
}

test_changed_runner_surfaces_select_their_family() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-owner-scope.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  # A change to the runner selects the WHOLE pure-contract-unit family, not
  # just its own contract test. The runner executes every script in that
  # family, so its own test passing proves its logic is right, not that the
  # suite it drives still runs. Narrowing this to the contract owners would
  # also make any wall-clock claim about the changed suite trivially true by
  # not running the work.
  printf '\n' >>"$repo/bin/fm-test-run.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD | LC_ALL=C sort)
  case "$listed" in
    *tests/fm-test-run.test.sh*) ;;
    *) fail "runner change did not select its own contract test: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-brief.test.sh*) ;;
    *) fail "runner change did not select its pure-contract-unit family: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-ask-user-authority.test.sh*) ;;
    *) fail "runner change did not select its pure-contract-unit family: $listed" ;;
  esac
  # The suite that proves the runner's per-suite fixture Git isolation lives in
  # the standalone family, which pure-contract-unit never reaches.
  case "$listed" in
    *tests/fm-test-fixtures.test.sh*) ;;
    *) fail "runner change did not select its fixture-isolation regression: $listed" ;;
  esac
  git -C "$repo" add bin/fm-test-run.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm runner-change

  # Documentation selects its contract owners rather than the execution family.
  printf '\n' >>"$repo/docs/fm-test-isolation-proof.md"
  printf '\n' >>"$repo/CONTRIBUTING.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD | LC_ALL=C sort)
  case "$listed" in
    *tests/fm-documentation-audiences.test.sh*) ;;
    *) fail "documentation surface change did not select audience coverage: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-brief.test.sh*) fail "documentation change selected an unrelated contract suite: $listed" ;;
    *) ;;
  esac

  rm -rf "$tmp"
  pass "runner retains broad execution coverage while documentation selects its owners"
}

test_shell_line_ending_policy_selects_runner_contract() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-attributes.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf '*.sh text eol=lf\n' >"$repo/.gitattributes"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-test-run.test.sh" \
    "shell line-ending policy selects the runner contract"
  rm -rf "$tmp"
  pass "shell line-ending policy selects runner coverage"
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "shared helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
  git -C "$repo" add tests/lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm helper-change

  printf '\n' >>"$repo/tests/git-config-helpers.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "git-config helper selects lib.sh dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "git-config helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "git-config helper selects snapshot dependents"
  git -C "$repo" add tests/git-config-helpers.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm git-config-helper-change

  # Split-test parts map to the wrappers that name them, without a curated
  # per-part entry in the runner.
  : >"$repo/tests/fm-pr-check-security-part.sh"
  printf '\n# tests/fm-pr-check-security-part.sh\n' >>"$repo/tests/fm-pr-check-security.test.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-check-security.test.sh" \
    "changed split-test part selects its wrapper suite"
  git -C "$repo" add tests/fm-pr-check-security-part.sh tests/fm-pr-check-security.test.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm split-test-part-change

  printf '\n' >>"$repo/tests/fm-backend-herdr-eventwait.test.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" "eventwait test selects Herdr coverage"
  assert_contains "$listed" "tests/fm-backend.test.sh" "eventwait test selects backend coverage"
  git -C "$repo" add tests/fm-backend-herdr-eventwait.test.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm eventwait-change

  printf '\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-daemon.test.sh" "supervisor target selects daemon coverage"
  assert_contains "$listed" "tests/fm-afk-return.test.sh" "supervisor target selects afk coverage"
  git -C "$repo" add bin/fm-supervisor-target-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm supervisor-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-ask-user-authority.test.sh" "skill source selects pure contract coverage"
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "Claude and Pi source selects hook coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  assert_contains "$listed" "tests/fm-pi-windows-shell-invocation.test.sh" \
    "turn-end extension selects native-Windows shell coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  printf '\n' >>"$repo/.pi/extensions/lib/fm-operational-input.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pi-windows-shell-invocation.test.sh" \
    "operational-input extension selects native-Windows shell coverage"
  git -C "$repo" add .pi/extensions/lib/fm-operational-input.ts
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm operational-input-source-change

  printf '\n' >>"$repo/.agents/skills/harness-adapters/references/common/dispatch.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-harness-adapter-references.test.sh" "harness adapter reference selects portable structural coverage"
  assert_contains "$listed" "tests/fm-harness-adapter-instructions-live-e2e.test.sh" "harness adapter reference selects opt-in instruction coverage"
  git -C "$repo" add .agents/skills/harness-adapters
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm harness-adapter-reference-change

  printf '\n' >>"$repo/.agents/skills/harness-adapters/SKILL.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-harness-adapter-references.test.sh" "harness adapter router selects portable structural coverage"
  assert_contains "$listed" "tests/fm-harness-adapter-instructions-live-e2e.test.sh" "harness adapter router selects opt-in instruction coverage"
  git -C "$repo" add .agents/skills/harness-adapters/SKILL.md
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm harness-adapter-router-change

  printf '\n' >>"$repo/bin/fm-procevent-quota.sh"
  printf '\n' >>"$repo/bin/fm-quota-choose.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "quota process-event source selects its focused test"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "quota chooser source selects its focused test"
  git -C "$repo" add bin/fm-procevent-quota.sh bin/fm-quota-choose.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm quota-source-change

  printf '\n' >>"$repo/bin/fm-quota-axi-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "shared quota validator selects process-event coverage"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "shared quota validator selects chooser coverage"
  git -C "$repo" add bin/fm-quota-axi-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm quota-validator-change

  printf '\n' >>"$repo/bin/fm-control-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend.test.sh" \
    "control library keeps backend coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "control library keeps session coverage"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "control library selects chooser coverage"
  git -C "$repo" add bin/fm-control-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm control-lib-change

  printf '\n' >>"$repo/bin/fm-timeout-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "timeout library selects quota polling coverage"
  git -C "$repo" add bin/fm-timeout-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm timeout-lib-change

  printf '\n' >>"$repo/src/unmapped.ts"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unmapped changed source must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: src/unmapped.ts' "$tmp/err" \
    || fail "unmapped changed source failure is not actionable: $(cat "$tmp/err")"

  rm -f "$repo/src/unmapped.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  [ -z "$listed" ] || fail "a retired unmapped source without consumers selected tests: $listed"

  : >"$repo/bin/no-reader-source.sh"
  git -C "$repo" add bin/no-reader-source.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm no-reader-source
  printf '\n' >>"$repo/bin/no-reader-source.sh"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a tracked source with no reader must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: bin/no-reader-source.sh' "$tmp/err" \
    || fail "a tracked source with no reader failure is not actionable: $(cat "$tmp/err")"
  [ "$(grep -c '^broad fallback: bin/no-reader-source.sh$' "$tmp/err")" -eq 1 ] \
    || fail "the broad fallback diagnostic must appear once per changed path: $(cat "$tmp/err")"
  rm -rf "$tmp"
  pass "changed selection covers dependents, fails closed for live unmapped source, and accepts retired unconsumed source"
}

# References select individual readers across mapped and unmapped sources.
test_changed_bin_reference_selects_per_script_not_per_family() {
  local tmp repo listed subject reader
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed-scope.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/bin/shared-probe-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)

  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" \
    "the one gated script that names the helper must still be selected"
  case "$listed" in
    *tests/fm-control-herdr-smoke.test.sh*)
      fail "a single gated script's reference dragged in its whole family: $listed"
      ;;
  esac
  assert_contains "$listed" "tests/fm-daemon.test.sh" \
    "the consumer of the helper must select its own reader"
  assert_not_contains "$listed" "tests/fm-pi-watch-extension.test.sh" \
    "a leaf consumer must not select unrelated watcher siblings"

  # A known direct owner must not hide executable consumers or shared helpers.
  for subject in fm-brief fm-watch fm-backend fm-watch-checkpoint; do
    repo="$tmp/$subject"
    mkdir -p "$repo/bin" "$repo/tests"
    cp "$RUNNER" "$repo/bin/fm-test-run.sh"
    printf 'echo executed\n' >"$repo/bin/$subject.sh"
    chmod +x "$repo/bin/$subject.sh"
    printf 'bash -c %q\n' ":; . \"$repo/bin/$subject.sh\"" >"$repo/bin/fm-test-isolation-proof.sh"
    printf '. "%s/bin/%s.sh"\n' "$repo" "$subject" >"$repo/tests/consumer-chain.sh"
    printf 'bash "%s/bin/%s.sh"\n' "$repo" "$subject" >"$repo/tests/direct.test.sh"
    printf 'bash "%s/bin/fm-test-isolation-proof.sh"\n' "$repo" >"$repo/tests/via-bin.test.sh"
    printf '. "%s/tests/consumer-chain.sh"\n' "$repo" >"$repo/tests/via-helper.test.sh"
    printf 'bash "%s/tests/via-bin.test.sh"\n' "$repo" >"$repo/tests/via-suite.test.sh"
    # shellcheck disable=SC2016  # literal fixture text: $ must not expand here.
    printf 'run() {\n  local lib="%s/bin/%s.sh"\n  . "$lib"\n}\nrun\n' "$repo" "$subject" >"$repo/bin/declared-consumer.sh"
    printf 'bash "%s/bin/declared-consumer.sh"\n' "$repo" >"$repo/tests/via-local.test.sh"
    printf 'if "%s/bin/%s.sh"; then :; fi\n' "$repo" "$subject" >"$repo/bin/control-consumer.sh"
    printf 'bash "%s/bin/control-consumer.sh"\n' "$repo" >"$repo/tests/via-control.test.sh"
    # shellcheck disable=SC2016  # literal fixture text: $ must not expand here.
    printf 'out=$("%s/bin/%s.sh")\nprintf "%%s\\n" "$out"\n' "$repo" "$subject" >"$repo/bin/subst-consumer.sh"
    printf 'bash "%s/bin/subst-consumer.sh"\n' "$repo" >"$repo/tests/via-subst.test.sh"
    printf 'echo unrelated\n' >"$repo/tests/unrelated.test.sh"
    git -C "$repo" init -q
    git -C "$repo" add .
    git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
    printf '\n' >>"$repo/bin/$subject.sh"
    listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
    for reader in direct via-bin via-helper via-suite via-local via-control via-subst; do
      assert_contains "$listed" "tests/$reader.test.sh" "$subject retains its $reader reader"
    done
    [ "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" -eq 7 ] || fail "$subject must select exactly its seven readers: $listed"
    for reader in via-bin via-helper via-suite via-local via-control via-subst; do
      [ "$(bash "$repo/tests/$reader.test.sh")" = executed ] || fail "$reader did not execute $subject"
    done
    git -C "$repo" checkout -q -- "bin/$subject.sh"
    printf '\n' >>"$repo/tests/via-bin.test.sh"
    listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
    assert_contains "$listed" tests/via-suite.test.sh "changed suite retains its executable wrapper"
    [ "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" -eq 2 ] || fail "changed suite must select itself and its wrapper: $listed"
  done
  rm -rf "$tmp"
  pass "bin references and consumer references select individual scripts"
}

# A long consumer chain and a cycle must reach the real reader; comment-only
# mentions, including inline comments, must not create consumer edges.
test_changed_reference_closure() {
  local tmp repo listed script
  tmp=$(fm_test_tmproot fm-selection-closure)
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  for script in one two three four; do : >"$repo/bin/$script.sh"; done
  printf '. "./two.sh"\n' >"$repo/bin/one.sh"
  printf '. "./three.sh"\n' >"$repo/bin/two.sh"
  printf '. "./four.sh"\n' >"$repo/bin/three.sh"
  printf '. "./one.sh"\n' >"$repo/bin/four.sh"
  printf '. "./one.sh"\n' >>"$repo/tests/fm-pr-merge.test.sh"
  printf '# four.sh\n: # four.sh\n' >"$repo/bin/comment-only.sh"
  printf '. "./comment-only.sh"\n' >>"$repo/tests/fm-backend.test.sh"
  # Quoted # is data and must not hide a genuine dependency later on the line.
  printf 'value="#"; . "./four.sh"\n' >"$repo/bin/quoted-hash.sh"
  printf '. "./quoted-hash.sh"\n' >>"$repo/tests/fm-secondmate-safety.test.sh"
  printf 'echo leaf-ran\n' >"$repo/bin/comment-leaf.sh"
  printf '. "%s/bin/comment-leaf.sh"\n' "$repo" >"$repo/bin/comment-consumer.sh"
  # shellcheck disable=SC2016  # literal fixture text: $ must not expand here.
  printf '# comment-leaf.sh\n. "$(dirname "$0")/../bin/comment-consumer.sh"\n' >"$repo/tests/fm-comment-reader.test.sh"
  # shellcheck disable=SC2016  # literal fixture text: $ must not expand here.
  printf 'bash "$(dirname "$0")/fm-comment-reader.test.sh"\n' >"$repo/tests/fm-comment-wrapper.test.sh"
  printf 'echo "ok - prose: source tests/fm-comment-reader.test.sh"\n' >"$repo/tests/fm-prose-reader.test.sh"
  # shellcheck disable=SC2016  # literal fixture text: $ must not expand here.
  printf 'bash "$(dirname "$0")/fm-prose-reader.test.sh"\n' >"$repo/tests/fm-prose-wrapper.test.sh"
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm chain
  printf '\n' >>"$repo/bin/four.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" tests/fm-pr-merge.test.sh "consumer closure reaches beyond two levels and terminates cycles"
  assert_contains "$listed" tests/fm-secondmate-safety.test.sh "a quoted hash keeps the executable dependency"
  assert_not_contains "$listed" tests/fm-backend.test.sh "comment-only consumers do not select tests"
  [ "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" -eq 2 ] || fail "leaf change widened beyond its two readers: $listed"
  rm "$repo/bin/four.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" tests/fm-pr-merge.test.sh "removed source still selects its remaining readers"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm remove-four
  printf '\n' >>"$repo/bin/comment-leaf.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" tests/fm-comment-reader.test.sh "an executable edge requeues a suite first seen through a comment"
  assert_contains "$listed" tests/fm-comment-wrapper.test.sh "a wrapper of that suite is selected"
  assert_not_contains "$listed" tests/fm-prose-reader.test.sh "prose naming a reader is not a suite reader"
  assert_not_contains "$listed" tests/fm-prose-wrapper.test.sh "prose naming a reader is not an executable wrapper edge"
  [ "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" -eq 2 ] || fail "comment edge widened beyond its reader and wrapper: $listed"
  [ "$(bash "$repo/tests/fm-comment-wrapper.test.sh")" = leaf-ran ] || fail "the selected wrapper did not execute the changed leaf"

  : >"$repo/bin/fanout-leaf.sh"
  # shellcheck disable=SC2016  # literal fixture text: $ must not expand here.
  printf '. "$(dirname "$0")/../bin/fanout-leaf.sh"\n' >"$repo/bin/thin-hub.sh"
  # shellcheck disable=SC2016  # literal fixture text: $ must not expand here.
  printf '. "$(dirname "$0")/../bin/fanout-leaf.sh"\n' >"$repo/bin/fat-hub.sh"
  for i in 1 2 3; do
    # shellcheck disable=SC2016  # literal fixture text: $ must not expand here.
    printf 'bash "$(dirname "$0")/../bin/thin-hub.sh"\n' >"$repo/tests/fm-thin-hub-$i.test.sh"
  done
  for i in 1 2 3 4; do
    # shellcheck disable=SC2016  # literal fixture text: $ must not expand here.
    printf 'bash "$(dirname "$0")/../bin/fat-hub.sh"\n' >"$repo/tests/fm-fat-hub-$i.test.sh"
  done
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm hub-fallback
  printf '\n' >>"$repo/bin/fanout-leaf.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" tests/fm-thin-hub-1.test.sh "a thin hub emits its executable reader"
  assert_not_contains "$listed" tests/fm-fat-hub-1.test.sh "an emitted hub reader suppresses the fat-hub fallback"
  [ "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" -eq 3 ] || fail "hub fallback widened past the emitted readers: $listed"
  git -C "$repo" checkout -q -- bin/fanout-leaf.sh
  pass "changed reference closure handles cycles, comments, prose, wrappers, hubs, and removals"
}

# Use the real inventory in a disposable copy, never execute its scripts here.
# Bounds catch family fan-out while positive assertions keep relevant coverage.
test_changed_real_inventory_selection_bounds() {
  local tmp repo listed count path reader id limit shared_lib_cases batch batch_paths
  tmp=$(fm_test_tmproot fm-selection-inventory)
  repo="$tmp/repo"
  mkdir -p "$repo"
  for path in bin tests docs .agents .pi .claude .github; do
    [ ! -d "$ROOT/$path" ] || cp -R "$ROOT/$path" "$repo/$path"
  done
  for path in AGENTS.md .no-mistakes.yaml .tasks.toml; do
    cp "$ROOT/$path" "$repo/$path"
  done
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline

  printf '\n' >>"$repo/AGENTS.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" tests/fm-documentation-audiences.test.sh "AGENTS changes retain audience coverage"
  assert_contains "$listed" tests/fm-agentsmd-size.test.sh "AGENTS changes retain the resident-size limit regression"
  git -C "$repo" checkout -q -- AGENTS.md

  printf '\n' >>"$repo/.agents/skills/bearings/SKILL.md"
  printf '\n' >>"$repo/docs/configuration.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ] && [ "$count" -le 10 ] || fail "docs/skill selection expected 1-10 scripts, got $count: $listed"
  assert_contains "$listed" tests/fm-documentation-audiences.test.sh "docs/skills retain their structural owner"
  assert_not_contains "$listed" tests/fm-calm-pi-extension.test.sh "docs do not select browser/Pi integration"
  assert_not_contains "$listed" tests/fm-test-run.test.sh "docs do not select runner integration"
  git -C "$repo" checkout -q -- .agents/skills/bearings/SKILL.md docs/configuration.md

  printf '\n' >>"$repo/.no-mistakes.yaml"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" tests/fm-lint-nomistakes-config.test.sh "no-mistakes config retains its contract owner"
  assert_contains "$listed" tests/fm-lint.test.sh "no-mistakes config retains the lint suite"
  assert_not_contains "$listed" tests/fm-calm-pi-extension.test.sh "no-mistakes config avoids browser/Pi integration"
  git -C "$repo" checkout -q -- .no-mistakes.yaml

  printf '\n' >>"$repo/.github/workflows/ci.yml"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" tests/fm-lint-workflows.test.sh "CI workflow retains its lint owner"
  assert_not_contains "$listed" tests/fm-calm-pi-extension.test.sh "CI workflow avoids browser/Pi integration"
  git -C "$repo" checkout -q -- .github/workflows/ci.yml

  printf '\n' >>"$repo/.github/workflows/no-mistakes-required.yml"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ] && [ "$count" -le 10 ] \
    || fail "required workflow selection expected 1-10 scripts, got $count: $listed"
  assert_contains "$listed" tests/fm-lint-workflows.test.sh "required workflow retains its lint owner"
  assert_contains "$listed" tests/fm-no-mistakes-required-live-lookup.test.sh \
    "required workflow retains its live lookup reader"
  git -C "$repo" checkout -q -- .github/workflows/no-mistakes-required.yml

  printf '\n' >>"$repo/.github/workflows/windows-herdr-spike.yml"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ] && [ "$count" -le 10 ] \
    || fail "workflow without a reader expected 1-10 scripts, got $count: $listed"
  assert_contains "$listed" tests/fm-lint-workflows.test.sh "workflow without a reader retains its lint owner"
  assert_not_contains "$listed" tests/fm-test-run.test.sh \
    "workflow without a reader avoids the pure-contract-unit family"
  git -C "$repo" checkout -q -- .github/workflows/windows-herdr-spike.yml

  printf '\n' >>"$repo/.tasks.toml"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" tests/fm-tasks-axi.test.sh "tasks config retains its tasks-axi owner"
  assert_not_contains "$listed" tests/fm-calm-pi-extension.test.sh "tasks config avoids browser/Pi integration"
  git -C "$repo" checkout -q -- .tasks.toml

  printf '\n' >>"$repo/docs/supervision-protocols/codex.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" tests/fm-supervision-instructions.test.sh "snippet retains its dynamic renderer"
  assert_contains "$listed" tests/fm-session-start.test.sh "snippet retains session-start integration"
  assert_not_contains "$listed" tests/fm-test-run.test.sh "snippet avoids runner integration"
  git -C "$repo" checkout -q -- docs/supervision-protocols/codex.md

  printf '\n' >>"$repo/bin/fm-returning-session-check.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ] && [ "$count" -le 40 ] || fail "leaf selection expected 1-40 scripts, got $count: $listed"
  assert_contains "$listed" tests/fm-returning-session-check.test.sh "leaf retains its behavior suite"
  git -C "$repo" checkout -q -- bin/fm-returning-session-check.sh

  # The recorded leaf that drove the intent: a shared wrapper must not fan out
  # into every suite that reaches it through shared libs or hub consumers.
  printf '\n' >>"$repo/bin/fm-context-usage.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ] && [ "$count" -le 40 ] \
    || fail "context-usage leaf expected 1-40 scripts (target 20-40 for a typical leaf), got $count: $listed"
  assert_contains "$listed" tests/fm-context-usage.test.sh "context-usage leaf retains its behavior suite"
  assert_contains "$listed" tests/fm-watch-triage.test.sh "context-usage leaf retains its watch-triage reader"
  assert_contains "$listed" tests/fm-watch-triage-waits.test.sh "context-usage leaf retains its waits reader"
  git -C "$repo" checkout -q -- bin/fm-context-usage.sh

  # Shared harnesses stop the walk, so a leaf stays bounded even when it is
  # reached through a command hub that a local test directly executes.
  for path in fm-watch-arm fm-procevent; do
    limit=40
    printf '\n' >>"$repo/bin/$path.sh"
    listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
    count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$count" -ge 1 ] && [ "$count" -le "$limit" ] \
      || fail "$path leaf expected 1-$limit scripts, got $count: $listed"
    if [ "$path" = fm-procevent ]; then
      assert_not_contains "$listed" tests/fm-grok-harness.test.sh "fm-procevent leaf avoids unrelated harness suites"
    fi
    git -C "$repo" checkout -q -- "bin/$path.sh"
  done

  # A hub's direct executable reader still runs the changed leaf, so the hub
  # boundary must select it even though the walk does not fan out further.
  printf '\n' >>"$repo/bin/fm-autonomous-pc02-lane.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ] && [ "$count" -le 40 ] || fail "hub leaf selection expected 1-40 scripts, got $count: $listed"
  assert_contains "$listed" tests/fm-pc02-test-offload.test.sh "hub change retains its direct executable reader"
  git -C "$repo" checkout -q -- bin/fm-autonomous-pc02-lane.sh

  printf '\n' >>"$repo/bin/fm-watch-checkpoint.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 2 ] && [ "$count" -le 60 ] || fail "watcher checkpoint selection expected 2-60 scripts, got $count: $listed"
  assert_contains "$listed" tests/fm-watch-checkpoint.test.sh "watcher change retains checkpoint behavior"
  assert_contains "$listed" tests/fm-arm-pretool-check.test.sh "watcher change retains its entrypoint guard"
  git -C "$repo" checkout -q -- bin/fm-watch-checkpoint.sh

  # A shared library is still expected to widen: its direct readers are the
  # suites that source it, so narrowing must not suppress that coverage.
  printf '\n' >>"$repo/bin/fm-wake-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 50 ] \
    || fail "shared watcher library should widen well past a leaf: got $count"
  git -C "$repo" checkout -q -- bin/fm-wake-lib.sh

  # An existing core source whose executable readers are all behind wide hubs
  # still selects those suites, even when a comment-only test was printed. Rows
  # are resolved in batches, and a batch only changes paths whose asserted reader
  # no other changed path in that batch emits, so a selected line cannot satisfy
  # another path's row.
  shared_lib_cases='1 fm-merge-authority-lib.sh fm-pr-merge.test.sh
1 fm-exclude-tools-lib.sh fm-control-relaunch.test.sh
1 fm-public-followup-collect.sh fm-public-followup.test.sh
2 fm-landed-lib.sh fm-bearings-snapshot.test.sh
2 fm-project-capacity-lib.sh fm-control-relaunch.test.sh'
  for batch in 1 2; do
    batch_paths=
    while read -r id path reader; do
      [ "$id" = "$batch" ] || continue
      printf '\n' >>"$repo/bin/$path"
      batch_paths="$batch_paths $path"
    done <<<"$shared_lib_cases"
    if ! listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>"$tmp/shared-lib-$batch.err"); then
      fail "shared library selection failed for$batch_paths: $(cat "$tmp/shared-lib-$batch.err" 2>/dev/null)"
    fi
    while read -r id path reader; do
      [ "$id" = "$batch" ] || continue
      assert_contains "$listed" "tests/$reader" "shared library $path selects its hub reader"
      git -C "$repo" checkout -q -- "bin/$path"
    done <<<"$shared_lib_cases"
  done

  # Recorded 18-file delta for https://github.com/sKeLe100/firstmate/pull/215.
  local -a recorded_paths=(
    .agents/skills/{bearings,stow,stuck-crewmate-recovery}/SKILL.md
    AGENTS.md
    bin/fm-{classify-lib,context-usage,crew-state,primary-watchdog}.sh
    bin/fm-{push-transition-lib,returning-session-check,supervise-daemon,watch}.sh
    docs/{architecture,configuration}.md
    tests/fm-{context-usage,crew-state,primary-watchdog,returning-session-check}.test.sh
  )
  for path in "${recorded_paths[@]}"; do printf '\n' >>"$repo/$path"; done
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 25 ] && [ "$count" -le 110 ] \
    || fail "recorded feature expected 25-110 scripts, below the original 196 and 306: got $count: $listed"
  for path in fm-context-usage fm-crew-state fm-primary-watchdog fm-returning-session-check fm-watch-triage fm-watch-triage-waits; do
    assert_contains "$listed" "tests/$path.test.sh" "recorded feature retains $path behavior"
  done
  pass "real inventory selection stays bounded for docs, skills, leaves, a watcher, a shared lib, and the recorded feature"
}

# Exercise begin/end markers from real fixture processes to prove the automatic
# changed-suite default and its explicit serial override.
test_changed_uses_bounded_automatic_concurrency() {
  local tmp repo script serial_shape parallel_shape timeout_repo timeout_script expected_jobs rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed-consent.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  for script in fm-backend-herdr-smoke.test.sh fm-daemon.test.sh fm-pi-watch-extension.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/../bin/shared-probe-lib.sh"
sleep 1
echo "ok - concurrency consent fixture"
SH
    chmod +x "$repo/tests/$script"
  done
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixtures
  printf '\n' >>"$repo/bin/shared-probe-lib.sh"

  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/parallel.json") \
    >"$tmp/parallel.out" 2>"$tmp/parallel.err" \
    || fail "default changed fixture run failed: $(cat "$tmp/parallel.err")"
  parallel_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/parallel.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$parallel_shape" = FM_TEST_BEGIN,FM_TEST_BEGIN ] \
    || fail "plain --changed did not use bounded concurrent scheduling: $parallel_shape"

  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --jobs 1 --json "$tmp/serial.json") \
    >"$tmp/serial.out" 2>"$tmp/serial.err" \
    || fail "explicit serial changed fixture run failed: $(cat "$tmp/serial.err")"
  serial_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/serial.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$serial_shape" = FM_TEST_BEGIN,FM_TEST_END ] \
    || fail "explicit --jobs 1 did not force serial execution: $serial_shape"
  expected_jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$expected_jobs" in
    ''|*[!0-9]*) expected_jobs=1 ;;
  esac
  [ "$expected_jobs" -le 4 ] || expected_jobs=4
  [ "$expected_jobs" -ge 1 ] || expected_jobs=1
  python3 - "$tmp/parallel.json" "$tmp/serial.json" "$expected_jobs" <<'PY' \
    || fail "changed timing artifacts did not record their resolved worker counts"
import json, sys
automatic = json.load(open(sys.argv[1], encoding="utf-8"))
serial = json.load(open(sys.argv[2], encoding="utf-8"))
expected = int(sys.argv[3])
assert automatic["selection"].split(";")[-1] == f"jobs={expected}"
assert serial["selection"].split(";")[-1] == "jobs=1"
PY

  timeout_repo="$tmp/timeout-repo"
  timeout_script=tests/fm-calm-pi-extension.test.sh
  mkdir -p "$timeout_repo/bin" "$timeout_repo/tests"
  cp "$RUNNER" "$timeout_repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$timeout_repo/tests/"
  cat >"$timeout_repo/bin/fm-timeout-lib.sh" <<'SH'
fm_run_timed() {
  [ "$1" -eq 1500 ] || return 99
  return 124
}
SH
  cat >"$timeout_repo/$timeout_script" <<'SH'
#!/usr/bin/env bash
touch should-not-run
echo "not ok - automatic timeout helper was bypassed"
SH
  chmod +x "$timeout_repo/bin/fm-test-run.sh" "$timeout_repo/$timeout_script"
  git -C "$timeout_repo" init -q
  git -C "$timeout_repo" add .
  git -C "$timeout_repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  printf '\n' >>"$timeout_repo/$timeout_script"
  set +e
  (cd "$timeout_repo" && bin/fm-test-run.sh --changed --base HEAD) \
    >"$tmp/timeout.out" 2>"$tmp/timeout.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "single-script automatic timeout must fail the run, got $rc"
  grep -Eq '^FM_TEST_END .+ tests/fm-calm-pi-extension\.test\.sh exit=124 ' "$tmp/timeout.out" \
    || fail "single unproven changed script did not receive the automatic timeout: $(cat "$tmp/timeout.out")"
  [ ! -e "$timeout_repo/should-not-run" ] || fail "automatic timeout helper did not own the single changed script"

  rm -rf "$tmp"
  pass "changed defaults to bounded automatic scheduling with serial override"
}

test_windows_posix_mode_emulation_does_not_fail_parallel_runs() {
  local tmp repo fakebin real_stat out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-windows-modes.XXXXXX")
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  real_stat=$(command -v stat)
  init_changed_fixture_repo "$repo"
  mkdir -p "$fakebin"
  cat >"$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME:-MINGW64_NT-10.0}"
SH
  cat >"$fakebin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = %a ]; then
  printf '%s\n' 755
  exit 0
fi
exec "$REAL_STAT" "$@"
SH
  chmod +x "$fakebin/uname" "$fakebin/stat"
  set +e
  out=$(cd "$repo" && PATH="$fakebin:$PATH" REAL_STAT="$real_stat" \
    bin/fm-test-run.sh --jobs 2 \
      tests/fm-cd-pretool-check.test.sh tests/fm-ask-user-authority.test.sh 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "native-Windows POSIX-mode emulation"
  assert_contains "$out" "FM_TEST_SUMMARY total=2 failed=0" \
    "Windows mode emulation did not complete both parallel scripts"

  set +e
  out=$(cd "$repo" && PATH="$fakebin:$PATH" REAL_STAT="$real_stat" FAKE_UNAME=CYGWIN_NT-10.0 \
    bin/fm-test-run.sh --jobs 2 \
      tests/fm-cd-pretool-check.test.sh tests/fm-ask-user-authority.test.sh 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "Cygwin POSIX-mode enforcement"
  assert_contains "$out" "isolation failure: worker root mode is 755, expected 0700" \
    "Cygwin mode enforcement did not reject a non-0700 worker root"
  rm -rf "$tmp"
  pass "Windows emulation exempts only synthetic POSIX modes"
}

# A local verification round names the subjects it cares about. Exercise begin/end
# markers from real fixture processes to prove that a plain list of script paths
# gets bounded automatic scheduling without changing its per-script timeout
# contract, so verifying several subjects is one bounded concurrent run rather
# than a serial chain of separate `bash tests/X.test.sh` invocations.
test_script_list_uses_bounded_automatic_concurrency() {
  local tmp repo script parallel_shape serial_shape mixed_shape expected_jobs
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-script-list.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  rm -f "$repo/bin/fm-timeout-lib.sh"
  # fm-cd-pretool-check and fm-pr-merge are individually proven isolated;
  # fm-backend-orca is not, so it must still land in the serial tail.
  for script in fm-cd-pretool-check.test.sh fm-pr-merge.test.sh fm-backend-orca.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - script-list concurrency fixture"
SH
    chmod +x "$repo/tests/$script"
  done

  (cd "$repo" && bin/fm-test-run.sh tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh \
      --json "$tmp/parallel.json") >"$tmp/parallel.out" 2>"$tmp/parallel.err" \
    || fail "default script-list run failed: $(cat "$tmp/parallel.err")"
  parallel_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/parallel.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$parallel_shape" = FM_TEST_BEGIN,FM_TEST_BEGIN ] \
    || fail "a plain script list did not use bounded concurrent scheduling: $parallel_shape"

  (cd "$repo" && bin/fm-test-run.sh tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh \
      --jobs 1 --json "$tmp/serial.json") >"$tmp/serial.out" 2>"$tmp/serial.err" \
    || fail "explicit serial script-list run failed: $(cat "$tmp/serial.err")"
  serial_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/serial.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$serial_shape" = FM_TEST_BEGIN,FM_TEST_END ] \
    || fail "explicit --jobs 1 did not force a serial script list: $serial_shape"

  # An unproven script in the list is scheduled around, never refused and never
  # run beside another script.
  (cd "$repo" && bin/fm-test-run.sh tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh \
      tests/fm-backend-orca.test.sh) >"$tmp/mixed.out" 2>"$tmp/mixed.err" \
    || fail "mixed proven/unproven script list failed: $(cat "$tmp/mixed.err")"
  mixed_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/mixed.out" | awk '{print $1}' | paste -sd, -)
  [ "$mixed_shape" = FM_TEST_BEGIN,FM_TEST_BEGIN,FM_TEST_END,FM_TEST_END,FM_TEST_BEGIN,FM_TEST_END ] \
    || fail "an unproven script was not kept in the serial tail: $mixed_shape"

  expected_jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$expected_jobs" in
    ''|*[!0-9]*) expected_jobs=1 ;;
  esac
  [ "$expected_jobs" -le 4 ] || expected_jobs=4
  [ "$expected_jobs" -ge 1 ] || expected_jobs=1
  python3 - "$tmp/parallel.json" "$tmp/serial.json" "$expected_jobs" <<'PYJSON' \
    || fail "script-list timing artifacts did not record their resolved worker counts"
import json, sys
automatic = json.load(open(sys.argv[1], encoding="utf-8"))
serial = json.load(open(sys.argv[2], encoding="utf-8"))
expected = int(sys.argv[3])
assert automatic["selection"].split(";")[-1] == f"jobs={expected}"
assert serial["selection"].split(";")[-1] == "jobs=1"
PYJSON

  (cd "$repo" && bin/fm-test-run.sh tests/fm-backend-orca.test.sh) \
    >"$tmp/named.out" 2>"$tmp/named.err" \
    || fail "a named script unexpectedly required a timeout helper: $(cat "$tmp/named.err")"
  grep -Eq '^FM_TEST_END .+ tests/fm-backend-orca\.test\.sh exit=0 ' "$tmp/named.out" \
    || fail "a named script did not run without an automatic bound: $(cat "$tmp/named.out")"

  rm -rf "$tmp"
  pass "a plain script list defaults to bounded automatic concurrency without an automatic timeout"
}

test_family_proofs_run_in_separate_concurrent_phases() {
  local tmp repo script
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-family-phases.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-calm-pi-extension.test.sh fm-vendor-auth-probe.test.sh \
    fm-pr-check-security.test.sh fm-teardown.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - family phase fixture"
SH
    chmod +x "$repo/tests/$script"
  done

  (cd "$repo" && bin/fm-test-run.sh \
      tests/fm-pr-check-security.test.sh tests/fm-calm-pi-extension.test.sh \
      tests/fm-teardown.test.sh tests/fm-vendor-auth-probe.test.sh --jobs 4) \
    >"$tmp/out" 2>"$tmp/err" \
    || fail "cross-family phase fixture failed: $(cat "$tmp/err")"

  python3 - "$tmp/out" <<'PY' \
    || fail "family-proof scripts from different families overlapped: $(cat "$tmp/out")"
import re, sys
active = {}
overlap = {"pure-contract-unit": False, "pr-forge": False}
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("FM_TEST_BEGIN "):
        match = re.search(r" (tests/\S+) family=(\S+) ", line)
        assert match, line
        path, family = match.groups()
        assert not active or set(active.values()) == {family}, (active, line)
        active[path] = family
        if sum(value == family for value in active.values()) > 1:
            overlap[family] = True
    elif line.startswith("FM_TEST_END "):
        match = re.search(r" (tests/\S+) exit=", line)
        assert match and match.group(1) in active, (active, line)
        del active[match.group(1)]
assert not active, active
assert all(overlap.values()), overlap
PY

  rm -rf "$tmp"
  pass "family proofs run concurrently only within separate family phases"
}

test_empty_selection_emits_summary() {
  local tmp repo out json rc fake_bin real_git
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  out=$(cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
    || fail "empty valid changed selection must pass"
  printf '%s\n' "$out" | grep -Eq \
    '^FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=[0-9]+$' \
    || fail "empty selection summary is missing or malformed: $out"
  json="$tmp/artifacts/timing.json"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"]["total"] == 0
assert doc["summary"]["failed"] == 0
assert doc["summary"]["skipped_gate"] == 0
assert doc["summary"]["duration_ms"] >= 0
assert doc["scripts"] == []
assert doc["families"] == []
' "$json" || { rm -rf "$tmp"; fail "empty selection JSON summary is wrong"; }
  fake_bin="$tmp/fake-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  cat >"$fake_bin/git" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$SLOW_GIT_MARKER" ]; then
  : >"$SLOW_GIT_MARKER"
  sleep 1
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$fake_bin/git"
  set +e
  (cd "$repo" && PATH="$fake_bin:$PATH" REAL_GIT="$real_git" SLOW_GIT_MARKER="$tmp/slow-git" \
    bin/fm-test-run.sh --changed --base HEAD --max-wall-ms 100) \
    >"$tmp/slow-selection.out" 2>"$tmp/slow-selection.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an empty run past its budget must fail normally, got $rc"
  grep -Eq '^FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=[0-9]+$' "$tmp/slow-selection.out" \
    || fail "over-budget empty selection omitted its summary"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=100 duration_ms=[0-9]+$' "$tmp/slow-selection.out" \
    || fail "over-budget empty selection omitted its budget result"
  [ -e "$tmp/slow-git" ] || fail "the slow selection fixture did not run"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --max-wall-ms nope) \
    >"$tmp/bad-budget.out" 2>"$tmp/bad-budget.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "malformed budget on an empty selection must be refused, got $rc"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --per-script-timeout-secs nope) \
    >"$tmp/bad-timeout.out" 2>"$tmp/bad-timeout.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "malformed timeout on an empty selection must be refused, got $rc"
  rm -rf "$tmp"
  pass "empty changed selection emits deterministic text and JSON summaries"
}

test_timing_markers_and_json() {
  local RUNNER="$FIXTURE_RUNNER"
  local tmp fixture out json begin_n end_n summary
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timing.XXXXXX")
  fixture="$tmp/ok.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$fixture"
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$out" || true)
  [ "$begin_n" -eq 1 ] || fail "expected one FM_TEST_BEGIN, got $begin_n"
  [ "$end_n" -eq 1 ] || fail "expected one FM_TEST_END, got $end_n"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$out" \
    || fail "BEGIN line missing family/expected_gate_skip: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || fail "END line missing exit/duration/gate_skip: $(grep '^FM_TEST_END' "$out")"
  summary=$(grep '^FM_TEST_SUMMARY ' "$out" || true)
  assert_contains "$summary" "total=1" "summary total"
  assert_contains "$summary" "failed=0" "summary failed"
  assert_contains "$summary" "skipped_gate=0" "summary skipped_gate"
  grep -q '^FM_TEST_SLOWEST rank=1 ' "$out" \
    || fail "expected FM_TEST_SLOWEST rank=1"
  [ -f "$json" ] || fail "JSON timing artifact was not written"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" \
    || fail "JSON timing artifact is not valid JSON"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert "scripts" in doc and len(doc["scripts"]) == 1, doc
assert doc["scripts"][0]["exit"] == 0
assert doc["scripts"][0]["gate_skip"] is False
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_aggregate_exit_behavior() {
  local RUNNER="$FIXTURE_RUNNER"
  local tmp pass_f fail_f rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  set +e
  "$RUNNER" "$pass_f" "$fail_f" >"$tmp/out.txt" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate exit must be non-zero when any script fails"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out.txt" \
    || fail "summary should report total=2 failed=1: $(grep FM_TEST_SUMMARY "$tmp/out.txt")"
  # All-green stays 0.
  set +e
  "$RUNNER" "$pass_f" >"$tmp/out2.txt" 2>"$tmp/err2.txt"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "aggregate exit must be 0 when every script passes"; }
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_gate_skip_accounting() {
  local RUNNER="$FIXTURE_RUNNER"
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "gate-skip fixture must exit 0 from the runner"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting is honest and non-failing"
}

test_gate_skip_reason_is_recorded() {
  local RUNNER="$FIXTURE_RUNNER"
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skipreason.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: live: fmnosuchharness absent"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "a capability skip must still exit 0 from the runner"
  grep -q 'live: fmnosuchharness absent' "$tmp/err.txt" \
    || fail "the runner log must name what this host could not exercise: $(cat "$tmp/err.txt")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
record = doc["scripts"][0]
assert record["gate_skip"] is True, record
assert record["gate_skip_reason"] == "live: fmnosuchharness absent", record
' "$json" || { rm -rf "$tmp"; fail "the timing artifact must carry the skip reason"; }
  rm -rf "$tmp"
  pass "a gate skip records why it skipped"
}

test_a_run_that_ran_records_no_skip_reason() {
  local RUNNER="$FIXTURE_RUNNER"
  local tmp ran_f json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-ranreason.XXXXXX")
  ran_f="$tmp/ran.test.sh"
  json="$tmp/timing.json"
  cat >"$ran_f" <<'SH'
#!/usr/bin/env bash
echo "ok - ran"
exit 0
SH
  chmod +x "$ran_f"
  "$RUNNER" --json "$json" "$ran_f" >"$tmp/out.txt" 2>&1 \
    || fail "a passing fixture must exit 0 from the runner"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
record = doc["scripts"][0]
assert record["gate_skip"] is False, record
assert record["gate_skip_reason"] == "", record
' "$json" || { rm -rf "$tmp"; fail "a script that ran must carry an empty skip reason"; }
  rm -rf "$tmp"
  pass "a script that actually ran records no skip reason"
}

test_live_guards_expect_a_capability_skip_class() {
  local RUNNER="$FIXTURE_RUNNER"
  local tmp out skip_f
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-liveclass.XXXXXX")
  out="$tmp/out.txt"
  skip_f="$tmp/fm-composer-matrix-live-e2e.test.sh"
  printf '#!/usr/bin/env bash\necho "skip: live: browser unavailable"\n' >"$skip_f"
  chmod +x "$skip_f"
  "$RUNNER" --json "$tmp/timing.json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "a live capability skip must not fail the runner: $(cat "$tmp/err.txt")"
  grep -q 'expected_gate_skip=live-capability' "$out" \
    || fail "the live-harness family must expect a capability skip: $(grep FM_TEST_BEGIN "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
record = doc["scripts"][0]
assert record["expected_gate_skip"] == "live-capability", record
assert record["gate_skip"] is True, record
assert record["gate_skip_reason"].startswith("live: "), record
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "the live guard record is wrong"; }
  rm -rf "$tmp"
  pass "live guards are recorded as a capability class, not a bare env opt-in"
}

test_fail_on_gate_skip_token() {
  local RUNNER="$FIXTURE_RUNNER"
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  "$RUNNER" --fail-on-gate-skip 'herdr not found' "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-gate-skip must make herdr-not-found a hard failure"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-gate-skip: $(grep FM_TEST_SUMMARY "$out")"
  grep -q 'required gate skip token' "$tmp/err.txt" \
    || fail "runner must log the required gate skip token"
  rm -rf "$tmp"
  pass "fail-on-gate-skip converts herdr-not-found into a hard failure"
}

test_exclude_family() {
  local listed
  listed=$("$RUNNER" --list --all --exclude-family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "exclude-family real-herdr-gated left a real-herdr script"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-lint.test.sh' \
    || fail "exclude-family must retain pure-contract-unit scripts"
  # Explicit family mode still works; exclude of a different family is a no-op.
  listed=$HERDR_FAMILY_LIST
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "family real-herdr-gated must list smoke test"
  pass "exclude-family drops the named primary family after selection"
}

test_exclude_quarantined() {
  local listed quarantine_file script signature reason owner tmp qfile out
  quarantine_file="$ROOT/tests/fm-test-quarantine.tsv"
  assert_present "$quarantine_file" "the tracked quarantine list is missing"

  # Every entry must name an existing test and retain the original four
  # fields; test_quarantine_diagnostics validates migrated evidence through
  # the public parser as well.
  while IFS=$'\t' read -r script signature reason owner; do
    [ -n "$script" ] || continue
    assert_present "$ROOT/$script" "quarantine entry names a missing script: $script"
    [ -n "$signature" ] || fail "quarantine entry for $script has an empty signature"
    [ -n "$reason" ] || fail "quarantine entry for $script has an empty reason"
    [ -n "$owner" ] || fail "quarantine entry for $script has an empty owner"
  done < <(grep -v '^[[:space:]]*#' "$quarantine_file" | grep -v '^[[:space:]]*$')

  tmp=$(fm_test_tmproot fm-test-quarantine)
  qfile="$tmp/q.tsv"
  printf '# comment\n\ntests/fm-transition-lib.test.sh\tsig-x\treason-x\towner-x\n' > "$qfile"

  # --exclude-quarantined drops exactly the listed scripts and keeps stdout a
  # clean path list; the loud markers go to stderr, not the path list.
  listed=$("$RUNNER" --quarantine-file "$qfile" --list --all --exclude-quarantined 2>/dev/null)
  printf '%s\n' "$listed" | grep -Fxq 'tests/fm-transition-lib.test.sh' \
    && fail "exclude-quarantined left a quarantined script selected"
  printf '%s\n' "$listed" | grep -Fxq 'tests/fm-lint.test.sh' \
    || fail "exclude-quarantined must retain non-quarantined scripts"
  assert_not_contains "$listed" "FM_TEST_QUARANTINED" \
    "--list stdout must stay a clean path list"

  # The flag is opt-in: without it nothing is excluded.
  listed=$("$RUNNER" --quarantine-file "$qfile" --list --all 2>/dev/null)
  printf '%s\n' "$listed" | grep -Fxq 'tests/fm-transition-lib.test.sh' \
    || fail "absence of --exclude-quarantined must keep the script"

  # An explicitly named quarantine list that is missing is refused, never a
  # silent change of selection.
  if out=$("$RUNNER" --quarantine-file "$tmp/missing.tsv" --list --all --exclude-quarantined 2>&1); then
    fail "a missing --quarantine-file must be refused"
  fi
  assert_contains "$out" "quarantine list not readable: $tmp/missing.tsv" \
    "a missing --quarantine-file must name the path"
  if out=$(FM_TEST_QUARANTINE_FILE="$tmp/missing.tsv" "$RUNNER" --list --all --exclude-quarantined 2>&1); then
    fail "a missing FM_TEST_QUARANTINE_FILE must be refused"
  fi

  # A run reports every quarantined skip loudly and runs nothing quarantined.
  # The fixture runner keeps this off the real suite and skips the real
  # environment record, neither of which the assertion depends on.
  printf 'tests/fm-fixture.test.sh\tsig-x\treason-x\towner-x\n' > "$tmp/fixture-q.tsv"
  out=$("$FIXTURE_RUNNER" --quarantine-file "$tmp/fixture-q.tsv" --exclude-quarantined \
    tests/fm-fixture.test.sh 2>/dev/null)
  assert_contains "$out" "FM_TEST_QUARANTINED tests/fm-fixture.test.sh" \
    "run mode must print the quarantined marker"
  assert_contains "$out" "FM_TEST_QUARANTINE_SUMMARY quarantined=1" \
    "run mode must print the quarantine summary"
  assert_contains "$out" "FM_TEST_SUMMARY total=0" \
    "a fully-quarantined selection runs nothing"

  pass "exclude-quarantined drops exactly the listed scripts and reports each skip loudly"
}

test_quarantine_diagnostics() {
  local tmp repo runner qfile out rc status line
  tmp=$(fm_test_tmproot fm-quarantine-diagnostics)
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/"
  runner="$repo/bin/fm-test-run.sh"
  qfile="$repo/tests/fm-test-quarantine.tsv"
  # Migrated rows carry reproduction context; old four-column rows still work.
  printf 'tests/fm-brief.test.sh\trecorded failure\treason\towner\tbase-sha; FAIL\thead-sha; FAIL\tfixture host\t2026-10-13\n' >"$qfile"
  printf 'tests/fm-pr-merge.test.sh\told symptom\treason\towner\n' >>"$qfile"
  printf 'echo "not ok - old symptom"; exit 1\n' >"$repo/tests/fm-pr-merge.test.sh"
  for status in matched changed newly-passing skipped additional; do
    case "$status" in
      matched) line='echo "not ok - recorded failure"; exit 1' ;;
      changed) line='echo "not ok - different failure"; exit 1' ;;
      newly-passing) line='echo "ok - original case passes"; exit 0' ;;
      skipped) line='echo "skip: missing capability"; exit 0' ;;
      additional) line='echo "not ok - recorded failure"; echo "not ok - new defect"; exit 1' ;;
    esac
    printf '%s\n' "$line" >"$repo/tests/fm-brief.test.sh"
    out=$("$runner" --diagnose-quarantined --all --jobs 1 --fail-fast --per-script-timeout-secs 5 2>&1) && rc=0 || rc=$?
    expect_code 0 "$rc" "diagnostic failures must not block the gate"
    [ "$status" != additional ] || status=changed
    assert_contains "$out" "FM_TEST_QUARANTINE_DIAGNOSTIC tests/fm-brief.test.sh status=$status" "wrong signature classification"
    assert_contains "$out" "FM_TEST_QUARANTINE_DIAGNOSTIC tests/fm-pr-merge.test.sh status=matched" "diagnostics must continue past first failure"
    assert_contains "$out" "FM_TEST_SUMMARY total=2" "diagnostics must select only quarantines"
    assert_contains "$out" "FM_TEST_QUARANTINE_EVIDENCE_INCOMPLETE tests/fm-pr-merge.test.sh" "legacy context must be visible"
  done
  out=$("$runner" --diagnose-quarantined --list --all --per-script-timeout-secs 5 2>/dev/null)
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 2 ] || fail "diagnostic list must contain only paths"
  # Ordinary gates retain the real failure, even with a quarantine file present.
  out=$("$runner" --jobs 1 tests/fm-pr-merge.test.sh 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "ordinary execution must still fail quarantined scripts"
  for line in \
    'tests/fm-brief.test.sh	sig	reason' \
    'tests/fm-brief.test.sh	sig	reason	owner	base	head	host	bad-date' \
    'tests/fm-brief.test.sh	sig	reason	owner		head	host	2026-10-13'; do
    printf '%b\n' "$line" >"$qfile"
    out=$("$runner" --exclude-quarantined --all --list 2>&1) && rc=0 || rc=$?
    expect_code 2 "$rc" "malformed quarantine evidence must refuse"
  done
  printf 'tests/fm-brief.test.sh\tsig\treason\towner\n' >"$qfile"
  cat "$qfile" "$qfile" >"$tmp/duplicate.tsv"
  out=$("$runner" --quarantine-file "$tmp/duplicate.tsv" --exclude-quarantined --all --list 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "duplicate quarantines must refuse"
  out=$("$runner" --diagnose-quarantined --all --per-script-timeout-secs 0 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "diagnostics must require a positive bound"
  out=$("$runner" --diagnose-quarantined --exclude-quarantined --all --per-script-timeout-secs 5 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "diagnostics must refuse exclusion"
  # Validate every migrated tracked record through the public parser.
  "$RUNNER" --quarantine-file "$ROOT/tests/fm-test-quarantine.tsv" --exclude-quarantined --all --list >"$tmp/list" \
    || fail "tracked migrated quarantine records are invalid"
  pass "quarantine diagnostics classify drift without weakening ordinary gates"
}

test_list_scheduled_proven_isolated_uses_serial_weights() {
  local tmp
  tmp=$(fm_test_tmproot fm-test-run-proven-schedule)
  "$RUNNER" --list --proven-isolated | LC_ALL=C sort >"$tmp/expected"
  "$RUNNER" --list-scheduled --proven-isolated >"$tmp/actual" \
    || fail "--list-scheduled --proven-isolated failed"
  cmp -s "$tmp/expected" "$tmp/actual" \
    || fail "proven-isolated scheduling must break serial-default ties by path"
  pass "proven-isolated scheduling ignores parallel hints"
}

test_list_scheduled_non_lane_selections_use_serial_weights() {
  local tmp repo script selection
  local -a scripts=(
    tests/fm-operational-input.test.sh
    tests/fm-lint.test.sh
    tests/fm-muse-harness.test.sh
    tests/fm-captain-hold-lifecycle.test.sh
    tests/fm-kimi-harness.test.sh
    tests/fm-brief.test.sh
  )
  tmp=$(fm_test_tmproot fm-test-run-non-lane-schedule)
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  for script in "${scripts[@]}"; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/$script"
    chmod +x "$repo/$script"
  done
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  for script in "${scripts[@]}"; do
    printf '\n' >>"$repo/$script"
  done
  printf '%s\n' \
    tests/fm-captain-hold-lifecycle.test.sh \
    tests/fm-kimi-harness.test.sh \
    tests/fm-muse-harness.test.sh \
    tests/fm-brief.test.sh \
    tests/fm-lint.test.sh \
    tests/fm-operational-input.test.sh >"$tmp/expected"
  for selection in family all changed scripts; do
    case "$selection" in
      family) set -- --family pure-contract-unit ;;
      all) set -- --all ;;
      changed) set -- --changed --base HEAD ;;
      scripts) set -- "${scripts[@]}" ;;
    esac
    "$repo/bin/fm-test-run.sh" --list-scheduled "$@" >"$tmp/actual" \
      || fail "--list-scheduled $selection failed"
    cmp -s "$tmp/expected" "$tmp/actual" \
      || fail "$selection scheduling must use serial hints and path-ordered default ties"
  done
  pass "family, all, changed, and script selections ignore parallel hints"
}

test_portable_shard_union_and_coverage_guard() {
  local s1 s2 proven serial herdr all_count union_count overlap out lane
  s1=$("$RUNNER" --list --lane portable-parallel-1)
  s2=$("$RUNNER" --list --lane portable-parallel-2)
  proven=$("$RUNNER" --list --proven-isolated)
  serial=$("$RUNNER" --list --lane portable-serial)
  herdr=$HERDR_FAMILY_LIST
  [ -n "$s1" ] && [ -n "$s2" ] || fail "portable parallel shards must be non-empty"
  # Shards disjoint.
  overlap=$(comm -12 <(printf '%s\n' "$s1" | LC_ALL=C sort) <(printf '%s\n' "$s2" | LC_ALL=C sort) || true)
  [ -z "$overlap" ] || fail "portable parallel shards overlap: $overlap"
  # Union of shards equals proven-isolated.
  [ "$(printf '%s\n' "$s1" "$s2" | LC_ALL=C sort -u)" = \
    "$(printf '%s\n' "$proven" | LC_ALL=C sort -u)" ] \
    || fail "shard union must equal proven-isolated set"
  # No herdr in portable lanes.
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "portable lanes must not include real-herdr-gated smoke"
  printf '%s\n' "$herdr" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "herdr family must include smoke"
  out=$COVERAGE_REPORT
  assert_contains "$out" "FM_TEST_COVERAGE ok" "coverage guard success marker"
  all_count=$(printf '%s\n' "$ALL_SUITE_LIST" | wc -l | tr -d ' ')
  union_count=$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$union_count" = "$all_count" ] \
    || fail "union of lanes ($union_count) must equal --all ($all_count)"
  # No duplicates across the four partitions.
  [ "$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" = "0" ] \
    || fail "lanes must not duplicate scripts"
  # LPT execution order, asserted against the runner's own measured schedule
  # rather than against a script name: naming the current longest script here is
  # what let the recorded lane duration go stale unnoticed in the first place.
  for lane in portable-parallel-1 portable-parallel-2; do
    [ "$("$RUNNER" --list --lane "$lane")" = "$("$RUNNER" --list-scheduled --lane "$lane")" ] \
      || fail "$lane membership must be stored longest-measured-first"
  done
  pass "portable shard union, disjointness, and coverage guard hold"
}

# The two parallel lanes are only "duration-balanced" while every member has a
# measured hint and the packing over those hints stays even. Both halves went
# unchecked until one lane grew past its CI job cap and was cancelled on every
# run, so assert them through the guard's own reported numbers.
test_portable_parallel_lanes_stay_duration_balanced() {
  local out max imbalance unhinted
  out=$COVERAGE_REPORT
  unhinted=$(printf '%s\n' "$out" | sed -n 's/.*parallel_unhinted=\([0-9]*\).*/\1/p')
  max=$(printf '%s\n' "$out" | sed -n 's/.*parallel_max_ms=\([0-9]*\).*/\1/p')
  imbalance=$(printf '%s\n' "$out" | sed -n 's/.*parallel_imbalance_ms=\([0-9]*\).*/\1/p')
  [ -n "$unhinted" ] && [ -n "$max" ] && [ -n "$imbalance" ] \
    || fail "coverage guard must report parallel_unhinted, parallel_max_ms, parallel_imbalance_ms: $out"
  [ "$unhinted" = "0" ] \
    || fail "$unhinted proven-isolated scripts have no measured parallel hint, so the lanes are packed on a guess"
  [ "$max" -gt 0 ] || fail "parallel_max_ms must be a positive packed duration, got $max"
  # 5% of the worst lane: wide enough that one script's growth does not trip it,
  # narrow enough that a lopsided partition cannot call itself balanced.
  [ "$((imbalance * 20))" -le "$max" ] \
    || fail "parallel lanes differ by ${imbalance}ms against a ${max}ms worst lane, more than 5%"
  pass "portable parallel lanes are fully hinted and packed within 5% of each other"
}

test_portable_serial_shards_partition_the_serial_lane() {
  local listed
  # The exhaustive real-inventory coverage guard checks all eleven shards for
  # nonempty, disjoint membership and exact union. Exercise the public valid
  # shard-list path once here; invalid shard names are checked below.
  listed=$("$RUNNER" --list --lane portable-serial-1of11)
  [ -n "$listed" ] || fail "portable serial shard 1 of 11 selected no tests"
  pass "portable serial shard listing is backed by the exhaustive coverage guard"
}

test_portable_serial_hint_coverage_is_reported_and_bounded() {
  local out serial unhinted max budget
  # Shards are packed from measured duration hints, so an unmeasured script is
  # placed on a guess. Enough of them and the partition still looks balanced by
  # script count while one shard carries far more real work than another and
  # reaches its CI job cap. The coverage guard therefore reports the unmeasured
  # share and refuses past its bound; assert that contract is live rather than
  # trusting the hint table to stay fresh on its own.
  out=$COVERAGE_REPORT
  assert_contains "$out" "serial_unhinted=" "coverage guard must report the unmeasured serial share"
  serial=$(printf '%s\n' "$out" | sed -n 's/.*[^_]serial=\([0-9][0-9]*\).*/\1/p')
  unhinted=$(printf '%s\n' "$out" | sed -n 's/.*serial_unhinted=\([0-9][0-9]*\).*/\1/p')
  [ -n "$serial" ] && [ -n "$unhinted" ] \
    || fail "coverage summary must carry numeric serial counts: $out"
  [ "$serial" -gt 0 ] || fail "portable serial lane must be non-empty, got $serial"
  [ "$unhinted" -le "$serial" ] \
    || fail "unmeasured count $unhinted exceeds the serial lane size $serial"
  # 15% is the guard's own bound; staying well inside it is what keeps the
  # balance evidence-based. Refresh from a green run's timing artifacts when
  # this trips (docs/fm-test-portable-shards.md).
  [ "$((unhinted * 100))" -le "$((serial * 15))" ] \
    || fail "$unhinted of $serial portable serial scripts lack a measured hint; refresh them"
  # A complete partition can still overflow a CI job. Assert the runner's
  # modeled packing target through its executable interface, not source hints.
  max=$(printf '%s\n' "$out" | sed -n 's/.*serial_max_ms=\([0-9][0-9]*\).*/\1/p')
  budget=$(printf '%s\n' "$out" | sed -n 's/.*serial_budget_ms=\([0-9][0-9]*\).*/\1/p')
  [ -n "$max" ] && [ -n "$budget" ] \
    || fail "coverage summary must carry serial packing and budget: $out"
  [ "$budget" -eq 1200000 ] || fail "packing must leave ten minutes of the normal CI tier"
  [ "$max" -gt 0 ] && [ "$max" -le "$budget" ] \
    || fail "largest serial shard packs ${max}ms above the ${budget}ms target"
  pass "coverage guard bounds the unmeasured share and serial packing within twenty minutes"
}

test_portable_serial_packing_budget_boundary() {
  local tmp repo weight out rc
  tmp=$(fm_test_tmproot fm-test-run-packing-boundary)
  repo="$tmp/repo"
  # The real inventory is checked once separately. A small executable
  # inventory keeps this exact policy boundary independent of its growth.
  init_lane_fixture_repo "$repo"

  for weight in 1200000 1200001; do
    cp "$RUNNER" "$repo/bin/fm-test-run.sh"
    python3 - "$repo/bin/fm-test-run.sh" "$weight" <<'PY' \
      || fail "could not seed the fixture's measured timing input"
from pathlib import Path
import re, sys
runner = Path(sys.argv[1])
runner.write_text(re.sub(
    r"(?m)^tests/fm-watch-triage\.test\.sh [0-9]+$",
    f"tests/fm-watch-triage.test.sh {sys.argv[2]}",
    runner.read_text(),
))
PY
    out=$(bash "$repo/bin/fm-test-run.sh" --check-coverage 2>&1) && rc=0 || rc=$?
    if [ "$weight" -eq 1200000 ]; then
      expect_code 0 "$rc" "packing exactly at the budget must be accepted"
      assert_contains "$out" "FM_TEST_COVERAGE ok" "boundary coverage did not pass"
      assert_contains "$out" "serial_max_ms=1200000" "fixture did not pack exactly at the budget"
      assert_contains "$out" "serial_budget_ms=1200000" "fixture changed the packing budget"
    else
      expect_code 1 "$rc" "packing one millisecond above the budget must be refused"
      assert_contains "$out" "largest portable serial shard packs 1200001ms above the 1200000ms target" \
        "over-budget refusal did not explain the modeled excess"
      assert_not_contains "$out" "FM_TEST_COVERAGE ok" "over-budget packing reported success"
    fi
  done
  pass "serial packing accepts the exact budget and refuses one millisecond above it"
}

test_portable_serial_shard_lane_refusals() {
  local RUNNER="$FIXTURE_RUNNER"
  local tmp count rc other
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-shard-lane.XXXXXX")
  count=11
  other=$((count + 1))

  # A lane built for a different shard count must refuse rather than run a
  # partial suite: this is what keeps a CI matrix from silently dropping tests.
  set +e
  "$RUNNER" --list --lane "portable-serial-1of${other}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "mismatched shard count must refuse (exit 2), got $rc"
  [ ! -s "$tmp/out" ] || fail "mismatched shard count must not list tests"
  grep -Fq "configured for $count" "$tmp/err" \
    || fail "mismatch refusal must name the configured count: $(cat "$tmp/err")"

  set +e
  "$RUNNER" --list --lane "portable-serial-$((count + 1))of${count}" >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "out-of-range shard index must refuse (exit 2), got $rc"
  grep -Fq "outside 1..$count" "$tmp/err2" \
    || fail "range refusal message missing: $(cat "$tmp/err2")"

  set +e
  "$RUNNER" --list --lane portable-serial-1 >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "shard lane without a count must refuse (exit 2), got $rc"
  rm -rf "$tmp"
  pass "portable serial shard lanes refuse mismatched, out-of-range, and countless names"
}

