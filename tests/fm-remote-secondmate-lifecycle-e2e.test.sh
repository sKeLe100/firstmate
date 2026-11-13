#!/usr/bin/env bash
# Full remote secondmate lifecycle over the deterministic generic SSH boundary,
# first stretch: home provisioning, seeding, launch, endpoint refusals, and the
# marked send and routed reply. The fixture and the remaining stretches are
# named in tests/fm-remote-secondmate-lifecycle-lib.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"
# shellcheck source=tests/fm-remote-secondmate-lifecycle-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-remote-secondmate-lifecycle-lib.sh"

seed_env() {
  FM_HOME="$TMP_ROOT/seed-parent" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_SSH_MODE="${FM_FAKE_SSH_MODE:-normal}" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_FAKE_SEED_ENTERED="$TMP_ROOT/seed.entered" \
  FM_FAKE_SEED_RELEASE="$TMP_ROOT/seed.release" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_FAKE_DOCTOR_REPAIRED="$TMP_ROOT/doctor.repaired" \
  "$@"
}

REAL_GIT=$(command -v git)
cat > "$FAKEBIN/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = clone ]; then
  case "\${!#}" in
    "$TMP_ROOT/concurrent-home"|"$TMP_ROOT"/.fm-home-provisioning.*)
      printf 'clone\n' >> "$TMP_ROOT/provision-clones"
      if mkdir "$TMP_ROOT/provision-first" 2>/dev/null; then
        touch "$TMP_ROOT/provision.entered"
        while [ ! -f "$TMP_ROOT/provision.release" ]; do sleep 0.02; done
      fi
      ;;
  esac
fi
if [ "\${1:-}" = clone ] && [ -n "\${FM_FAKE_CLONE_HOLD_DIR:-}" ] \
  && [ "\$(dirname "\${!#}")" = "\$FM_FAKE_CLONE_HOLD_DIR" ]; then
  hold_dest="\${!#}"
  "$REAL_GIT" "\$@" &
  hold_git=\$!
  hold_state() { ps -o stat= -p "\$hold_git" 2>/dev/null | tr -d '[:space:]'; }
  while [ ! -d "\$hold_dest/.git/objects" ]; do
    case "\$(hold_state)" in ''|Z*) wait "\$hold_git"; exit \$? ;; esac
    sleep 0.005
  done
  kill -STOP "\$hold_git" 2>/dev/null || true
  while :; do
    case "\$(hold_state)" in
      T*) break ;;
      ''|Z*) wait "\$hold_git"; exit \$? ;;
    esac
    sleep 0.005
  done
  touch "$TMP_ROOT/race-clone.held"
  while [ ! -f "$TMP_ROOT/race-clone.release" ] && [ -d "$TMP_ROOT" ]; do sleep 0.02; done
  kill -CONT "\$hold_git" 2>/dev/null || true
  wait "\$hold_git"
  exit \$?
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$FAKEBIN/git"
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=0\n' \
  "$(printf ios | base64 | tr -d '\n')" \
  "$(printf 'Concurrent provisioning charter.\n' | base64 | tr -d '\n')" \
  > "$TMP_ROOT/provision.manifest"
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/concurrent-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/provision.manifest" \
  > "$TMP_ROOT/provision-one.out" 2>&1 &
provision_one=$!
provision_wait=0
while [ ! -f "$TMP_ROOT/provision.entered" ]; do
  kill -0 "$provision_one" 2>/dev/null || fail "first provisioning attempt exited before cloning"
  provision_wait=$((provision_wait + 1))
  [ "$provision_wait" -le "$EVENT_WAIT_TICKS" ] || fail "first provisioning attempt never reached cloning"
  sleep 0.02
done
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/concurrent-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/provision.manifest" \
  > "$TMP_ROOT/provision-two.out" 2>&1 &
provision_two=$!
sleep 0.2
[ "$(grep -cF clone "$TMP_ROOT/provision-clones")" -eq 1 ] \
  || fail "overlapping provisioning reached home classification concurrently"
touch "$TMP_ROOT/provision.release"
wait "$provision_one" || fail "first serialized provisioning attempt failed"
wait "$provision_two" || fail "reconciled provisioning attempt failed"
[ "$(cat "$TMP_ROOT/concurrent-home/.fm-secondmate-home")" = ios ] \
  || fail "serialized provisioning lost the published home"
[ "$(grep -cF clone "$TMP_ROOT/provision-clones")" -eq 1 ] \
  || fail "reconciled provisioning cloned the already-published home"
pass "overlapping remote home provisioning serializes through publication and rollback"

# A competing cleanup aimed at the public home path must never reach a clone
# that is still being written: the home clone is staged privately and published
# by rename, so the racing rm -rf finds only an absent path.
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=0\n' \
  "$(printf race | base64 | tr -d '\n')" \
  "$(printf 'Cleanup-race provisioning charter.\n' | base64 | tr -d '\n')" \
  > "$TMP_ROOT/race.manifest"
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/raced-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_FAKE_CLONE_HOLD_DIR="$TMP_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/race.manifest" \
  > "$TMP_ROOT/race-provision.out" 2>&1 &
race_provision=$!
race_wait=0
while [ ! -f "$TMP_ROOT/race-clone.held" ]; do
  kill -0 "$race_provision" 2>/dev/null || fail "provision exited before its clone could be held"
  race_wait=$((race_wait + 1))
  [ "$race_wait" -le "$EVENT_WAIT_TICKS" ] || fail "provision clone never reached the held point"
  sleep 0.02
done
rm -rf -- "$TMP_ROOT/raced-home"
touch "$TMP_ROOT/race-clone.release"
wait "$race_provision" \
  || { sed 's/^/race-provision: /' "$TMP_ROOT/race-provision.out"; fail "competing home cleanup reached a live provisioning clone"; }
[ "$(cat "$TMP_ROOT/raced-home/.fm-secondmate-home")" = race ] \
  || fail "raced provisioning lost its published home marker"
if [ "$(git -C "$TMP_ROOT/raced-home" rev-parse --show-toplevel 2>/dev/null)" = "$TMP_ROOT/raced-home" ] \
  && [ "$(git -C "$TMP_ROOT/raced-home" rev-parse HEAD)" = "$(git -C "$REMOTE_ROOT" rev-parse HEAD)" ] \
  && git -C "$TMP_ROOT/raced-home" fsck --full --no-progress >/dev/null 2>&1 \
  && [ -z "$(git -C "$TMP_ROOT/raced-home" status --porcelain)" ] \
  && cmp -s "$REMOTE_ROOT/AGENTS.md" "$TMP_ROOT/raced-home/AGENTS.md"; then
  :
else
  fail "raced provisioning published an incomplete clone"
fi
if find "$TMP_ROOT" -maxdepth 1 -name '.fm-home-provisioning.*' -print -quit | grep -q .; then
  fail "raced provisioning left staging litter beside the home"
fi
pass "competing cleanup of the public home cannot reach a live provisioning clone"

# A home that appears at the public path while the clone is staged must make
# the provision die without adopting, altering, or nesting into that home.
rm -f -- "$TMP_ROOT/race-clone.held" "$TMP_ROOT/race-clone.release"
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/appeared-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_FAKE_CLONE_HOLD_DIR="$TMP_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/race.manifest" \
  > "$TMP_ROOT/appeared-provision.out" 2>&1 &
appeared_provision=$!
race_wait=0
while [ ! -f "$TMP_ROOT/race-clone.held" ]; do
  kill -0 "$appeared_provision" 2>/dev/null || fail "appeared-home provision exited before its clone could be held"
  race_wait=$((race_wait + 1))
  [ "$race_wait" -le "$EVENT_WAIT_TICKS" ] || fail "appeared-home provision clone never reached the held point"
  sleep 0.02
done
mkdir "$TMP_ROOT/appeared-home"
printf 'foreign\n' > "$TMP_ROOT/appeared-home/foreign"
touch "$TMP_ROOT/race-clone.release"
if wait "$appeared_provision"; then
  fail "provision adopted a home that appeared while it was being provisioned"
fi
grep -qF "remote home appeared while it was being provisioned" "$TMP_ROOT/appeared-provision.out" \
  || { sed 's/^/appeared-provision: /' "$TMP_ROOT/appeared-provision.out"; fail "appeared-home provision died for the wrong reason"; }
[ "$(find "$TMP_ROOT/appeared-home" -mindepth 1 | wc -l | tr -d ' ')" -eq 1 ] \
  && [ "$(cat "$TMP_ROOT/appeared-home/foreign")" = foreign ] \
  || fail "provision altered a home that appeared while it was being provisioned"
if find "$TMP_ROOT" -maxdepth 1 -name '.fm-home-provisioning.*' -print -quit | grep -q .; then
  fail "appeared-home provisioning left staging litter beside the home"
fi
pass "a home that appears mid-provision makes the provision die without touching it"
if [ "${FM_TEST_PROVISION_ONLY:-0}" = 1 ]; then
  echo "ALL TESTS PASSED"
  exit 0
fi

mkdir -p "$TMP_ROOT/seed-parent/data" "$TMP_ROOT/seed-parent/state"
FM_SECONDMATE_CHARTER='Failing seed charter.' FM_SECONDMATE_SCOPE='failed seed' \
  FM_FAKE_SSH_MODE=provision-block-fail seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-fail remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-fail-home" --no-projects \
  > "$TMP_ROOT/seed-fail.out" 2>&1 &
seed_fail_pid=$!
seed_wait=0
while [ ! -f "$TMP_ROOT/seed.entered" ]; do
  kill -0 "$seed_fail_pid" 2>/dev/null || fail "failing seed exited before remote provisioning"
  seed_wait=$((seed_wait + 1))
  [ "$seed_wait" -le "$EVENT_WAIT_TICKS" ] || fail "failing seed never reached remote provisioning"
  sleep 0.02
done
FM_SECONDMATE_CHARTER='Successful seed charter.' FM_SECONDMATE_SCOPE='successful seed' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-keep remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-keep-home" --no-projects > "$TMP_ROOT/seed-keep.out" 2>&1 &
seed_keep_pid=$!
sleep 0.2
kill -0 "$seed_keep_pid" 2>/dev/null || fail "competing seed bypassed the shared registry transaction"
touch "$TMP_ROOT/seed.release"
if wait "$seed_fail_pid"; then
  fail "known-failing seed unexpectedly succeeded"
fi
wait "$seed_keep_pid" || fail "serialized successful seed failed"
assert_no_grep '- seed-fail ' "$TMP_ROOT/seed-parent/data/secondmates.md" "failed seed route survived rollback"
assert_grep '- seed-keep ' "$TMP_ROOT/seed-parent/data/secondmates.md" "failed seed rollback removed a competing successful route"
assert_present "$TMP_ROOT/seed-keep-home/.fm-secondmate-home" "serialized seed lost its published remote home"
pass "remote seed rollback preserves serialized competing routes"

: > "$DOCTOR_LOG"
if FM_SECONDMATE_CHARTER='Unknown readiness charter.' FM_SECONDMATE_SCOPE='unknown readiness' \
  FM_FAKE_SSH_MODE=doctor-fix-unknown seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-unknown remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-unknown-home" --no-projects \
  > "$TMP_ROOT/seed-unknown.out" 2>&1; then
  fail "seeding claimed success after readiness repair completion became unknown"
fi
assert_grep 'remote readiness completion is unknown' "$TMP_ROOT/seed-unknown.out" \
  "unknown readiness did not report its distinct completion state"
assert_grep '- seed-unknown ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "unknown readiness removed the registered route"
assert_present "$TMP_ROOT/seed-parent/data/seed-unknown/brief.md" \
  "unknown readiness removed the scaffolded brief"
assert_absent "$TMP_ROOT/seed-unknown-home" \
  "unknown readiness proceeded into remote home provisioning"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fix-unknown -
doctor-fix-unknown --fix' ] || fail "unknown readiness did not occur during the repair stage"$'\n'"$(cat "$DOCTOR_LOG")"
pass "unknown readiness preserves its route and brief for reconciliation"

# A host that cannot hold a durable second mate must be rejected by the
# readiness gate before any home is created on it, and the operator must get the
# gap text rather than a bare refusal.
: > "$DOCTOR_LOG"
if FM_SECONDMATE_CHARTER='Unready host charter.' FM_SECONDMATE_SCOPE='unready host' \
  FM_FAKE_SSH_MODE=doctor-human seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-toolless remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-toolless-home" --no-projects \
  > "$TMP_ROOT/seed-toolless.out" 2>&1; then
  fail "seeding proceeded against a host that is not ready for a remote second mate"
fi
assert_grep 'check gui-session=human:' \
  "$TMP_ROOT/seed-toolless.out" "the seed hid the remaining human gap"
assert_grep 'action: gui-session:' \
  "$TMP_ROOT/seed-toolless.out" "the seed hid the operator step that closes the gap"
assert_grep 'remote runtime preflight failed' "$TMP_ROOT/seed-toolless.out" \
  "the seed did not report the failing stage"
assert_absent "$TMP_ROOT/seed-toolless-home" "the seed provisioned a home despite a failing preflight"
assert_no_grep '- seed-toolless ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "the refused route survived the preflight rollback"
assert_absent "$TMP_ROOT/seed-parent/data/seed-toolless/brief.md" \
  "the refused route left its scaffolded charter behind"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-human -
doctor-human --fix
doctor-human -' ] || fail "the seed did not run the check, repair, re-check sequence"$'\n'"$(cat "$DOCTOR_LOG")"
pass "remote seeding checks, repairs, and re-checks readiness, then stops on a remaining gap"

# The same gate must accept a host whose only gaps were repairable.
: > "$DOCTOR_LOG"
rm -f "$TMP_ROOT/doctor.repaired"
out=$(FM_SECONDMATE_CHARTER='Repairable host charter.' FM_SECONDMATE_SCOPE='repairable host' \
  FM_FAKE_SSH_MODE=doctor-fixable seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-repair remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-repair-home" --no-projects 2>&1) \
  || fail "seeding refused a host whose gaps the repair closed"$'\n'"$out"
assert_present "$TMP_ROOT/seed-repair-home/.fm-secondmate-home" "the repaired host was never provisioned"
assert_grep '- seed-repair ' "$TMP_ROOT/seed-parent/data/secondmates.md" "the repaired route was not registered"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fixable -
doctor-fixable --fix
doctor-fixable -' ] || fail "the repaired seed did not re-check after its repair"$'\n'"$(cat "$DOCTOR_LOG")"
pass "remote seeding proceeds once the repair closes every gap"

# Seeding must not need a copy of the project in this home: firstmate names the
# origin it already resolved, the seed validates and transports it, and the
# primary project tree is left exactly as it was found.
projects_snapshot() { # <dir>
  local dir=$1 path
  (
    cd "$dir" 2>/dev/null || exit 0
    find . -print | LC_ALL=C sort | while IFS= read -r path; do
      if [ -f "$path" ] && [ ! -L "$path" ]; then
        printf '%s %s\n' "$path" "$(sha256_file "$path")"
      else
        printf '%s\n' "$path"
      fi
    done
  )
}
mkdir -p "$TMP_ROOT/seed-parent/projects"
fm_git_init_commit "$TMP_ROOT/seed-parent/projects/resident"
# Pin the bare origin's initial branch to the one fm_git_init_commit creates.
# Left to init.defaultBranch, its HEAD names a branch the push never creates on
# a host that still defaults to master, and cloning it checks out nothing.
git init -q --bare -b main "$TMP_ROOT/beta.git"
fm_git_init_commit "$TMP_ROOT/beta-src"
git -C "$TMP_ROOT/beta-src" remote add origin "file://$TMP_ROOT/beta.git"
git -C "$TMP_ROOT/beta-src" push -q -u origin HEAD
rm -rf "$TMP_ROOT/beta-src"
cat > "$TMP_ROOT/seed-parent/data/projects.md" <<'EOF'
- beta [direct-PR] - beta project (added 2026-08-06)
- delta [local-only] - delta project (added 2026-08-06)
EOF
BETA_ORIGIN="file://$TMP_ROOT/beta.git"
PROJECTS_BEFORE=$(projects_snapshot "$TMP_ROOT/seed-parent/projects")

if FM_SECONDMATE_CHARTER='Unsupplied origin charter.' FM_SECONDMATE_SCOPE='unsupplied origin' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-noorigin remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-noorigin-home" beta > "$TMP_ROOT/seed-noorigin.out" 2>&1; then
  fail "seeding an uncloned project with no origin claimed success"
fi
assert_grep 'pass beta=<origin-url>' "$TMP_ROOT/seed-noorigin.out" \
  "the refusal did not name how to supply the origin"
assert_absent "$TMP_ROOT/seed-noorigin-home" "the unresolvable origin still provisioned a remote home"

if FM_SECONDMATE_CHARTER='Unsafe origin charter.' FM_SECONDMATE_SCOPE='unsafe origin' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-unsafe remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-unsafe-home" 'beta=ext::git-upload-pack' \
  > "$TMP_ROOT/seed-unsafe.out" 2>&1; then
  fail "seeding accepted a remote-helper origin the remote host would execute"
fi
assert_grep 'not an accepted clone URL' "$TMP_ROOT/seed-unsafe.out" \
  "the unsafe-origin refusal did not name the reason"
assert_absent "$TMP_ROOT/seed-unsafe-home" "the unsafe origin still provisioned a remote home"

if FM_SECONDMATE_CHARTER='Local-only charter.' FM_SECONDMATE_SCOPE='local only' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-localonly remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-localonly-home" "delta=$BETA_ORIGIN" \
  > "$TMP_ROOT/seed-localonly.out" 2>&1; then
  fail "a supplied origin bypassed the local-only delivery-mode refusal"
fi
assert_grep 'is local-only and cannot be provisioned remotely' "$TMP_ROOT/seed-localonly.out" \
  "the local-only refusal did not name the registered mode"

if FM_SECONDMATE_CHARTER='Unregistered charter.' FM_SECONDMATE_SCOPE='unregistered' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-unregistered remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-unregistered-home" "gamma=$BETA_ORIGIN" \
  > "$TMP_ROOT/seed-unregistered.out" 2>&1; then
  fail "a supplied origin bypassed the project registry requirement"
fi
assert_grep 'has no registry record' "$TMP_ROOT/seed-unregistered.out" \
  "the unregistered-project refusal did not name the missing record"

out=$(FM_SECONDMATE_CHARTER='Own beta delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='beta delivery and validation' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-noclone remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-noclone-home" "beta=$BETA_ORIGIN" 2>&1) \
  || fail "seeding refused a registered project whose origin was supplied"$'\n'"$out"
assert_contains "$out" "home=remote-mac:$TMP_ROOT/seed-noclone-home" \
  "the no-clone seed did not report the host-qualified home"
assert_grep '- seed-noclone ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "the no-clone seed did not register the remote route"
assert_present "$TMP_ROOT/seed-noclone-home/projects/beta/README.md" \
  "the remote host did not clone the supplied origin"
[ "$(git -C "$TMP_ROOT/seed-noclone-home/projects/beta" remote get-url origin)" = "$BETA_ORIGIN" ] \
  || fail "the remote clone did not come from the supplied origin"
assert_grep '- beta [direct-PR]' "$TMP_ROOT/seed-noclone-home/data/projects.md" \
  "the remote home did not publish the project's registered posture"
assert_absent "$TMP_ROOT/seed-parent/projects/beta" \
  "seeding cloned the project into the primary project tree"
[ "$(projects_snapshot "$TMP_ROOT/seed-parent/projects")" = "$PROJECTS_BEFORE" ] \
  || fail "seeding changed the primary project tree"
pass "remote seeding provisions a supplied origin without touching the primary project tree"

# The receiving host validates the origin itself rather than trusting whatever
# reached it, so a manifest naming an executable transport provisions nothing.
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=1\nproject=%s|%s|%s|%s\n' \
  "$(printf unsafe-origin | base64 | tr -d '\n')" \
  "$(printf 'Unsafe origin manifest charter.\n' | base64 | tr -d '\n')" \
  "$(printf beta | base64 | tr -d '\n')" \
  "$(printf 'ext::git-upload-pack' | base64 | tr -d '\n')" \
  "$(printf -- '- beta [direct-PR] - beta project (added 2026-08-06)' | base64 | tr -d '\n')" \
  "$(printf direct-PR | base64 | tr -d '\n')" \
  > "$TMP_ROOT/unsafe-origin.manifest"
if FM_HOME="$TMP_ROOT/unsafe-origin-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/unsafe-origin.manifest" \
  > "$TMP_ROOT/unsafe-origin.out" 2>&1; then
  fail "remote provisioning accepted an origin the transport had not validated"
fi
assert_grep 'not an accepted clone URL' "$TMP_ROOT/unsafe-origin.out" \
  "remote provisioning did not name the rejected origin"
assert_absent "$TMP_ROOT/unsafe-origin-home" "the rejected manifest left a remote home behind"
pass "remote provisioning re-validates a supplied origin at the receiving host"

# Firstmate is a shared template, so seeding must carry a project origin from any
# forge or host, not a privileged one. These four URL shapes have to survive the
# parent's validation, the manifest, the transport, and the receiving host's own
# validation, and arrive at git unchanged. A fixture resolver records the exact
# clone source the remote side hands to git and then serves it from a local bare
# repository, because an offline run cannot reach bitbucket.org itself.
FORGE_CLONE_LOG="$TMP_ROOT/forge-clone.log"
FORGE_ORIGIN_MAP="$TMP_ROOT/forge-origin.map"
: > "$FORGE_CLONE_LOG"
: > "$FORGE_ORIGIN_MAP"
forge_project() { # <project> <origin-url>
  local project=$1 origin=$2 tab
  tab=$(printf '\t')
  fm_git_init_commit "$TMP_ROOT/forge-src-$project"
  printf 'served from %s\n' "$origin" > "$TMP_ROOT/forge-src-$project/ORIGIN.txt"
  git -C "$TMP_ROOT/forge-src-$project" add ORIGIN.txt
  git -C "$TMP_ROOT/forge-src-$project" \
    -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm origin
  git clone --quiet --bare "$TMP_ROOT/forge-src-$project" "$TMP_ROOT/forge-$project.git"
  rm -rf "$TMP_ROOT/forge-src-$project"
  printf '%s%s%s\n' "$origin" "$tab" "$TMP_ROOT/forge-$project.git" >> "$FORGE_ORIGIN_MAP"
  printf -- '- %s [direct-PR] - %s project (added 2026-08-06)\n' "$project" "$project" \
    >> "$TMP_ROOT/seed-parent/data/projects.md"
}
forge_project bitbucket-app 'https://bitbucket.org/team/bitbucket-app.git'
forge_project ghe-app 'https://git.example.com/org/ghe-app.git'
forge_project gitlab-app 'ssh://git@gitlab.self.hosted:2222/group/subgroup/gitlab-app.git'
forge_project scp-app 'git@host.internal:group/scp-app.git'

cat > "$REMOTE_ROOT/bin/git" <<SH
#!/usr/bin/env bash
# Fixture origin resolver for the remote side: record the clone source exactly as
# the production code hands it to git, then serve any recorded URL from a local
# bare repository so the run stays offline. Everything else is real git.
set -u
if [ "\${1:-}" = clone ]; then
  printf '%s\n' "\$*" >> '$FORGE_CLONE_LOG'
  args=()
  for arg in "\$@"; do
    replacement=\$(awk -v k="\$arg" -F'\t' '\$1 == k { print \$2; exit }' '$FORGE_ORIGIN_MAP' 2>/dev/null)
    if [ -n "\$replacement" ]; then args+=("\$replacement"); else args+=("\$arg"); fi
  done
  exec '$REAL_GIT' "\${args[@]}"
fi
exec '$REAL_GIT' "\$@"
SH
chmod +x "$REMOTE_ROOT/bin/git"

FORGE_HOME="$TMP_ROOT/seed-forge-home"
out=$(FM_SECONDMATE_CHARTER='Own delivery for projects hosted anywhere.' \
  FM_SECONDMATE_SCOPE='multi-forge delivery' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-forge remote-mac "$REMOTE_ROOT" \
  "$FORGE_HOME" \
  'bitbucket-app=https://bitbucket.org/team/bitbucket-app.git' \
  'ghe-app=https://git.example.com/org/ghe-app.git' \
  'gitlab-app=ssh://git@gitlab.self.hosted:2222/group/subgroup/gitlab-app.git' \
  'scp-app=git@host.internal:group/scp-app.git' 2>&1) \
  || fail "seeding refused origins hosted outside GitHub"$'\n'"$out"

while IFS="$(printf '\t')" read -r forge_origin _; do
  [ -n "$forge_origin" ] || continue
  assert_grep "$forge_origin" "$FORGE_CLONE_LOG" \
    "the remote host did not clone from the supplied origin $forge_origin"
done < "$FORGE_ORIGIN_MAP"
for forge_project_name in bitbucket-app ghe-app gitlab-app scp-app; do
  assert_present "$FORGE_HOME/projects/$forge_project_name/.git" \
    "the remote home has no clone for $forge_project_name"
  assert_grep "$forge_project_name" "$FORGE_HOME/data/projects.md" \
    "the remote registry omitted $forge_project_name"
  assert_absent "$TMP_ROOT/seed-parent/projects/$forge_project_name" \
    "seeding $forge_project_name cloned it into the primary project tree"
done
# Each clone must carry its own origin's content, so one shared fixture repo
# cannot make a mismatched route look routed.
[ "$(cat "$FORGE_HOME/projects/bitbucket-app/ORIGIN.txt")" = \
  'served from https://bitbucket.org/team/bitbucket-app.git' ] \
  || fail "the bitbucket route did not clone its own origin"
[ "$(cat "$FORGE_HOME/projects/scp-app/ORIGIN.txt")" = \
  'served from git@host.internal:group/scp-app.git' ] \
  || fail "the scp-like route did not clone its own origin"
[ "$(projects_snapshot "$TMP_ROOT/seed-parent/projects")" = "$PROJECTS_BEFORE" ] \
  || fail "seeding non-GitHub projects changed the primary project tree"
assert_grep '- seed-forge ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "the multi-forge route was not registered"

rm -f "$REMOTE_ROOT/bin/git"
[ -z "$(git -C "$REMOTE_ROOT" status --porcelain)" ] \
  || fail "the fixture origin resolver was left behind in the remote code root"
pass "seeding carries bitbucket, self-hosted, and scp-like origins through to the remote clone"

# Provision and register the remote route from the captain-facing primary.
out=$(seed_ios_route "$REMOTE_HOME")
assert_contains "$out" "home=remote-mac:$REMOTE_HOME" "remote seed did not report the host-qualified home"
assert_grep 'host: remote-mac; root:' "$PARENT/data/secondmates.md" "registry did not record the remote host dimension"
assert_present "$REMOTE_HOME/.fm-secondmate-home" "remote provisioning did not publish the identity marker"
assert_present "$REMOTE_HOME/projects/alpha/.git" "remote provisioning did not clone the project on that host"
assert_grep "$REMOTE_HOME/state/parent-replies.status" "$REMOTE_HOME/data/charter.md" "remote charter did not use its append-only reply log"
assert_no_grep "$PARENT/state/ios.status" "$REMOTE_HOME/data/charter.md" "remote charter retained the inaccessible local status path"
assert_grep "$PARENT_ROUTE_INBOX" "$REMOTE_HOME/data/charter.md" "remote charter did not name its host-local steering inbox"
assert_no_grep "$PARENT/state/ios.inbox" "$REMOTE_HOME/data/charter.md" "remote charter retained the inaccessible local steering inbox path"
assert_grep "$PARENT_ROUTE_INBOX'/NNN.msg '$PARENT_ROUTE_INBOX'/handled/" "$REMOTE_HOME/data/charter.md" "remote charter did not render the inbox acknowledgement move host-local"
if seed_ios_route "$TMP_ROOT/other-home" >/dev/null 2>&1; then
  fail "remote seed allowed an existing id to move to another home"
fi
assert_grep "home: $REMOTE_HOME" "$PARENT/data/secondmates.md" "refused remote reassignment changed the durable route"
pass "remote seed registers the route and provisions the whole home and project clone on that host"

PROTOCOL_HOME="$TMP_ROOT/protocol-home"
mkdir -p "$PROTOCOL_HOME/config" "$PROTOCOL_HOME/data" "$PROTOCOL_HOME/state"
printf 'complete inherited payload\n' > "$TMP_ROOT/inherit-complete"
inherit_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/inherit-complete" | tr -d ' ')
inherit_hash=$(sha256_file "$TMP_ROOT/inherit-complete")
if printf 'complete' | FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_bytes" "$inherit_hash" 1 >/dev/null 2>&1; then
  fail "remote inheritance published a truncated payload"
fi
assert_absent "$PROTOCOL_HOME/config/crew-harness" "truncated inheritance published a destination"
FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_bytes" "$inherit_hash" 2 \
  < "$TMP_ROOT/inherit-complete" >/dev/null
printf 'stale inherited payload\n' > "$TMP_ROOT/inherit-stale"
inherit_stale_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/inherit-stale" | tr -d ' ')
inherit_stale_hash=$(sha256_file "$TMP_ROOT/inherit-stale")
if FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_stale_bytes" "$inherit_stale_hash" 1 \
  < "$TMP_ROOT/inherit-stale" >/dev/null 2>&1; then
  fail "remote inheritance accepted a superseded payload generation"
fi
cmp -s "$TMP_ROOT/inherit-complete" "$PROTOCOL_HOME/config/crew-harness" \
  || fail "superseded inheritance replaced the current payload"
pass "remote inheritance rejects incomplete and superseded payload generations"

# Add one local route to prove mixed fleets remain parseable and projected.
add_local_route
remote_env "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "mixed local and remote registry validation failed"
pass "mixed local and remote routes validate without migration"

# Launch on the remote home's own configured backend. Parent metadata records
# host placement separately from that backend and arms the reply source.
printf 'pi\n' > "$PARENT/config/crew-harness"
launches_before_inherit=0
[ ! -f "$HERDR_LOG" ] || launches_before_inherit=$(grep -c '^tab create' "$HERDR_LOG" || true)
if FM_FAKE_SSH_MODE=inherit-partial remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-inherit-partial.out" 2>&1; then
  fail "remote spawn launched after ambiguous partial inheritance"
fi
launches_after_inherit=0
[ ! -f "$HERDR_LOG" ] || launches_after_inherit=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_inherit" -eq "$launches_after_inherit" ] \
  || fail "remote spawn reached launch after ambiguous partial inheritance"
assert_absent "$PARENT/state/ios.meta" "failed remote inheritance published launch metadata"
out=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate)
assert_contains "$out" 'remote=remote-mac backend=herdr' "remote spawn did not report separate host and backend dimensions"
assert_grep 'remote_host=remote-mac' "$PARENT/state/ios.meta" "parent metadata omitted the remote host"
assert_grep 'remote_backend=herdr' "$PARENT/state/ios.meta" "parent metadata omitted the remote-local backend"
assert_grep 'remote_herdr_session=fm-remote' "$PARENT/state/ios.meta" "parent metadata omitted the pinned remote Herdr session"
assert_grep 'remote_target=fm-remote:' "$PARENT/state/ios.meta" "parent metadata did not record an fm-remote endpoint"
assert_grep 'herdr_session=fm-remote' "$REMOTE_HOME/state/parent-route/ios.meta" "remote metadata did not record the pinned Herdr session"
assert_grep '--session fm-remote' "$HERDR_LOG" "remote launch did not target the fm-remote session"
assert_no_grep '--session default' "$HERDR_LOG" "remote launch targeted the interactive default session"
assert_grep 'window=remote:ios' "$PARENT/state/ios.meta" "parent metadata pretended the endpoint was local"
assert_present "$PARENT/state/procevent/remote-reply-ios.source" "remote spawn did not arm its reply source"
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$ROOT/bin/fm-watch.sh"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "remote endpoint was not projected alive from its own host"
# Herdr reports a native agent state, so the delivery observation resolves
# without the rendered-output fallback a tmux endpoint needs.
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh observe ios)" = idle ] \
  || fail "remote endpoint delivery observation did not execute on its own host"
pass "remote spawn launches on the remote-local backend and records a host-qualified route"

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-default-session.meta"
legacy_pane=$(sed -n 's/^herdr_pane_id=//p' "$remote_route_meta")
awk -v pane="$legacy_pane" '
  /^window=/ { print "window=default:" pane; next }
  /^herdr_session=/ { print "herdr_session=default"; next }
  { print }
' "$TMP_ROOT/remote-ios-before-default-session.meta" > "$remote_route_meta"
cp "$HERDR_LOG" "$TMP_ROOT/herdr-before-default-session.log"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios 2>/dev/null)" = unverified ] \
  || fail "legacy default-session metadata was not classified unverified"
if remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh route ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh send ios probe >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh key ios Enter >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh capture ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh observe ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh retire ios --force >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh launch ios codex - - herdr >/dev/null 2>&1; then
  fail "legacy default-session metadata remained operational"
fi
cmp -s "$TMP_ROOT/herdr-before-default-session.log" "$HERDR_LOG" \
  || fail "legacy default-session metadata caused a Herdr operation"
assert_present "$REMOTE_HOME" "refused legacy retirement removed the remote home"
assert_grep 'herdr_session=default' "$remote_route_meta" "refused legacy retirement rewrote endpoint metadata"

awk -v pane="$legacy_pane" '
  /^window=/ { print "window=default:" pane; next }
  { print }
' "$TMP_ROOT/remote-ios-before-default-session.meta" > "$remote_route_meta"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios 2>/dev/null)" = unverified ] \
  || fail "mismatched fm-remote target was not classified unverified"
cmp -s "$TMP_ROOT/herdr-before-default-session.log" "$HERDR_LOG" \
  || fail "mismatched fm-remote target caused a Herdr operation"
mv -f "$TMP_ROOT/remote-ios-before-default-session.meta" "$remote_route_meta"
pass "legacy and mismatched remote endpoints fail closed before backend access"

cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-before-nonherdr.meta"
cp "$PARENT/data/secondmates.md" "$TMP_ROOT/registry-before-nonherdr.md"
set +e
FM_FAKE_SSH_MODE=launch-nonherdr-route remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-nonherdr-route.out" 2>&1
nonherdr_parent_rc=$?
set -e
[ "$nonherdr_parent_rc" -ne 0 ] || fail "parent accepted a non-herdr remote launch route"
assert_grep "remote launch returned backend 'tmux', expected herdr" "$TMP_ROOT/spawn-nonherdr-route.out" \
  "parent refusal did not name the returned remote backend"
cmp -s "$TMP_ROOT/parent-ios-before-nonherdr.meta" "$PARENT/state/ios.meta" \
  || fail "parent rewrote its endpoint metadata after a non-herdr route refusal"
cmp -s "$TMP_ROOT/registry-before-nonherdr.md" "$PARENT/data/secondmates.md" \
  || fail "parent removed or changed the registry route after a non-herdr route refusal"

set +e
FM_FAKE_SSH_MODE=launch-default-session-route remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-default-session-route.out" 2>&1
default_session_parent_rc=$?
set -e
[ "$default_session_parent_rc" -ne 0 ] || fail "parent accepted an interactive default-session remote route"
assert_grep "remote launch returned Herdr session 'default', expected 'fm-remote'" "$TMP_ROOT/spawn-default-session-route.out" \
  "parent refusal did not name the default session"
cmp -s "$TMP_ROOT/parent-ios-before-nonherdr.meta" "$PARENT/state/ios.meta" \
  || fail "parent rewrote its endpoint metadata after a default-session route refusal"

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-legacy.meta"
cat > "$remote_route_meta" <<EOF
window=firstmate:fm-ios
worktree=$REMOTE_HOME
project=$REMOTE_ROOT
harness=codex
kind=secondmate
backend=tmux
EOF
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-legacy-before-refusal.meta"
printf 'fm-ios|%s\n' "$REMOTE_HOME" > "$TMUX_STATE"
set +e
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh launch ios codex - - herdr \
  > "$TMP_ROOT/legacy-alive-refusal.out" 2>&1
legacy_alive_rc=$?
set -e
[ "$legacy_alive_rc" -ne 0 ] || fail "remote control reused an alive legacy tmux endpoint"
assert_grep "endpoint is recorded on backend 'tmux', expected 'herdr'" "$TMP_ROOT/legacy-alive-refusal.out" \
  "remote refusal did not name the endpoint's recorded backend"
cmp -s "$TMP_ROOT/remote-ios-legacy-before-refusal.meta" "$remote_route_meta" \
  || fail "remote refusal changed the legacy endpoint metadata"
assert_present "$TMUX_STATE" "remote refusal killed the alive legacy endpoint"
cmp -s "$TMP_ROOT/registry-before-nonherdr.md" "$PARENT/data/secondmates.md" \
  || fail "remote legacy refusal removed or changed the registry route"
mv -f "$TMP_ROOT/remote-ios-before-legacy.meta" "$remote_route_meta"
rm -f "$TMUX_STATE"
pass "non-herdr remote endpoints are refused without changing either route"

rm -f "$TMP_ROOT/inherit.entered" "$TMP_ROOT/inherit.release" "$TMP_ROOT/inherit.payload"
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
stale spawn preference
EOF
FM_FAKE_SSH_MODE=inherit-block remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-concurrent.out" 2>&1 &
spawn_concurrent=$!
spawn_inherit_wait=0
spawn_inherit_total=0
# shellcheck disable=SC2034 # read by name in ssh_progress_reset
spawn_ssh_seen=''
# Earlier inherited files traverse the worker before captain-shared.md, one
# remote round-trip each, so bound the wait by the gap between round-trips
# rather than its total to reach this deliberately blocked write.
while [ ! -f "$TMP_ROOT/inherit.entered" ]; do
  kill -0 "$spawn_concurrent" 2>/dev/null || fail "remote spawn exited before its blocked inheritance write"
  ssh_progress_reset spawn_inherit_wait spawn_ssh_seen
  spawn_inherit_wait=$((spawn_inherit_wait + 1))
  spawn_inherit_total=$((spawn_inherit_total + 1))
  [ "$spawn_inherit_wait" -le "$EVENT_WAIT_TICKS" ] && [ "$spawn_inherit_total" -le "$REMOTE_WAIT_TICKS" ] || fail "remote spawn never reached its blocked inheritance write"
  sleep 0.02
done
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
current post-spawn preference
EOF
remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/spawn-concurrent-push.out" 2>&1 &
spawn_config_push=$!
sleep 0.2
kill -0 "$spawn_config_push" 2>/dev/null \
  || fail "config push bypassed the active remote spawn inheritance transaction"
touch "$TMP_ROOT/inherit.release"
wait "$spawn_concurrent" || fail "serialized remote spawn failed"
wait "$spawn_config_push" || fail "config push failed after serialized remote spawn"$'\n'"$(cat "$TMP_ROOT/spawn-concurrent-push.out")"
[ "$(tail -1 "$REMOTE_HOME/data/captain-shared.md")" = 'current post-spawn preference' ] \
  || fail "stale spawn inheritance overwrote later config convergence"
pass "remote spawn serializes inheritance through launch publication"

# A normal marked parent request traverses SSH as a durable remote inbox
# record plus a rung doorbell - the payload is never typed into the pane. An
# ambiguous transport (the remote leg executed, then ssh exit 255) is retried
# identically once, and the idempotent remote write lands both executions on
# ONE record; the send reports itself unconfirmed with a correlation-preserving
# resend command, and the expectation resolves only after the correlated remote log
# delta is ingested.
ssh_before_send=$(cat "$SSH_COUNT")
records_before_send=$(find "$PARENT_ROUTE_INBOX" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
set +e
FM_FAKE_SSH_MODE=ambiguous remote_env "$ROOT/bin/fm-send.sh" fm-ios \
  'report the build result' > "$TMP_ROOT/send.out" 2> "$TMP_ROOT/send.err"
send_rc=$?
set -e
[ "$send_rc" -ne 0 ] || fail "ambiguous remote send claimed definite delivery"
assert_grep 'Only the correlation-reusing resend below is idempotent' "$TMP_ROOT/send.err" "ambiguous remote send did not state the correlation-preserving resend boundary"
assert_no_grep 'do not resend' "$TMP_ROOT/send.err" "ambiguous remote send kept the deleted do-not-resend trap"
ssh_after_send=$(cat "$SSH_COUNT")
[ "$ssh_after_send" -eq $((ssh_before_send + 2)) ] \
  || fail "ambiguous remote send was not retried exactly once (ssh calls: $((ssh_after_send - ssh_before_send)))"
records_after_send=$(find "$PARENT_ROUTE_INBOX" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
[ "$records_after_send" -eq $((records_before_send + 1)) ] \
  || fail "the retried remote steer did not dedup onto one new record, went $records_before_send -> $records_after_send"
assert_no_grep 'report the build result' "$HERDR_LOG" "the steer payload was typed into the remote pane"
assert_grep 'Firstmate instruction waiting' "$HERDR_LOG" "the remote doorbell never rang"
CORR=$(newest_remote_inbox_corr)
[ -n "$CORR" ] || fail "remote send did not carry a correlation token"
assert_grep "FM_PENDING_REPLY_EXISTING_CORR=$CORR" "$TMP_ROOT/send.err" "ambiguous remote send did not print its correlation-reusing command"
phase=$(grep '^phase=' "$PARENT/state/pending-replies/$CORR" | cut -d= -f2-)
[ "$phase" = delivery_unknown ] || fail "ambiguous remote send did not preserve its pending expectation"
printf 'done [corr=%s]: remote build passed\n' "$CORR" >> "$REMOTE_HOME/state/parent-replies.status"
RESULT=$(next_reply_result)
await_reply_result "$RESULT" \
  || fail "remote reply source did not capture the correlated answer"
RESULT_SEQ=${RESULT%.result}
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios "${RESULT_SEQ##*.}" "$RESULT" >/dev/null \
  || fail "remote reply ingest failed"
assert_grep "done [corr=$CORR]: remote build passed" "$PARENT/state/ios.status" "correlated remote reply did not reach the parent status channel"
phase=$(grep '^phase=' "$PARENT/state/pending-replies/$CORR" | cut -d= -f2-)
[ "$phase" = resolved ] || fail "correlated remote reply did not resolve the parent expectation"
pass "marked send and routed reply complete through the existing parent correlation owner"

echo "ALL TESTS PASSED"
