#!/usr/bin/env bash
# tests/fm-nomistakes-gate-check.test.sh - behavior tests for
# bin/fm-nomistakes-gate-check.sh. Exercises the four detection outcomes
# (equal, ahead, behind, diverged) and error paths (no remote, bad config,
# unknown branch) against a throwaway git repository.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$here/.." && pwd)"
SCRIPT="$ROOT/bin/fm-nomistakes-gate-check.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*" >&2; }

# --- fixtures ------------------------------------------------------------

# Create a working repo with commits, then set up a bare no-mistakes repo
# pointing to one of its commits as the gate. Returns the gate commit SHA.
#
# mk_gate_work <dir> <msg>   - creates a working repo with one commit,
#                               returns the commit SHA.
# mk_nm_remote <workdir> <gate-sha> <config-path>
#                             - creates a bare no-mistakes repo from
#                               workdir's history and writes gate config.
# mk_workdir <dir>
#                             - creates an empty git workdir with a branch.

mk_gate_work() {
  local dir=$1 msg=${2:-gate commit}
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.name 'Test'
  git -C "$dir" config user.email 'test@example.invalid'
  printf '# %s\n' "$msg" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -qm "$msg"
  git -C "$dir" rev-parse HEAD
}

# Create a bare no-mistakes repo and write gate config.
# The gate commit must already be accessible (via a separate gate_dir).
mk_nm_remote() {
  local nm_dir=$1 gate_sha=$2
  mkdir -p "$nm_dir"
  git init --bare -q "$nm_dir"
  printf 'v2:%s\n' "$gate_sha" > "$nm_dir/no-mistakes-gate-config"
}

mk_workdir() {
  local dir=$1 branch=${2:-main}
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.name 'Test'
  git -C "$dir" config user.email 'test@example.invalid'
  git -C "$dir" checkout -b "$branch" -q 2>/dev/null || true
}

# --- 1. equal: gate hash matches HEAD -------------------------------------

test_equal() {
  local gate_dir="$tmp/gate-equal" nm_dir="$tmp/nm-equal" workdir="$tmp/work-equal" gate_sha
  gate_sha=$(mk_gate_work "$gate_dir" "gate commit")
  mk_nm_remote "$nm_dir" "$gate_sha"
  mk_workdir "$workdir"
  (
    cd "$workdir"
    git remote add no-mistakes "$nm_dir"
    # Fetch the gate commit into the workdir directly
    git fetch "$gate_dir" "$gate_sha" 2>/dev/null || true
    git reset --hard "$gate_sha" 2>/dev/null || true
  )
  set +e
  out="$("$SCRIPT" "$workdir" 2>"$tmp/err")"
  rc=$?
  set -e
  [ "$out" = "equal" ] || fail "equal: expected 'equal', got '$out' (exit=$rc, err=$(cat "$tmp/err"))"
  pass "1. equal"
}

# --- 2. ahead: HEAD is ahead of the gate (gate is ancestor of HEAD) -------

test_ahead() {
  local gate_dir="$tmp/gate-ahead" nm_dir="$tmp/nm-ahead" workdir="$tmp/work-ahead" gate_sha
  gate_sha=$(mk_gate_work "$gate_dir" "gate commit")
  mk_nm_remote "$nm_dir" "$gate_sha"
  mk_workdir "$workdir"
  (
    cd "$workdir"
    git remote add no-mistakes "$nm_dir"
    git fetch "$gate_dir" "$gate_sha" 2>/dev/null || true
    git reset --hard "$gate_sha" 2>/dev/null || true
    # Add a new commit ahead of gate
    printf '# local\n' > local.txt
    git add local.txt
    git commit -qm "local work"
  )
  set +e
  out="$("$SCRIPT" "$workdir" 2>"$tmp/err")"
  rc=$?
  set -e
  [ "$out" = "ahead" ] || fail "ahead: expected 'ahead', got '$out' (exit=$rc, err=$(cat "$tmp/err"))"
  pass "2. ahead"
}

# --- 3. behind: gate is ahead of HEAD (HEAD is ancestor of gate) ----------

test_behind() {
  local gate_dir="$tmp/gate-behind" nm_dir="$tmp/nm-behind" workdir="$tmp/work-behind" base_sha gate_sha
  # Create base commit in gate_dir
  base_sha=$(mk_gate_work "$gate_dir" "base")
  # Advance the gate repo with another commit
  (
    cd "$gate_dir"
    printf '# gate advance\n' > advance.txt
    git add advance.txt
    git commit -qm "gate advance"
  )
  gate_sha=$(git -C "$gate_dir" rev-parse HEAD)
  # Create a bare no-mistakes repo and push all commits into it
  mk_nm_remote "$nm_dir" "$gate_sha"
  (
    cd "$gate_dir"
    git remote add nm "$nm_dir"
    git push nm master:master 2>/dev/null || true
  )
  # Workdir has the base commit but gate is ahead
  mk_workdir "$workdir"
  (
    cd "$workdir"
    git remote add no-mistakes "$nm_dir"
    git fetch no-mistakes 2>/dev/null || true
    git reset --hard "$base_sha" 2>/dev/null || true
  )
  set +e
  out="$("$SCRIPT" "$workdir" 2>"$tmp/err")"
  rc=$?
  set -e
  [ "$out" = "behind" ] || fail "behind: expected 'behind', got '$out' (exit=$rc, err=$(cat "$tmp/err"))"
  pass "3. behind"
}

# --- 4. diverged: neither is an ancestor of the other --------------------

test_diverged() {
  local gate_dir="$tmp/gate-diverged" nm_dir="$tmp/nm-diverged" workdir="$tmp/work-diverged" base_sha gate_sha
  base_sha=$(mk_gate_work "$gate_dir" "base")
  # Gate advances on one path
  (
    cd "$gate_dir"
    printf '# gate path\n' > gate.txt
    git add gate.txt
    git commit -qm "gate path"
  )
  gate_sha=$(git -C "$gate_dir" rev-parse HEAD)
  # Push gate commits to bare nm repo
  mk_nm_remote "$nm_dir" "$gate_sha"
  (
    cd "$gate_dir"
    git remote add nm "$nm_dir"
    git push nm master:master 2>/dev/null || true
  )
  mk_workdir "$workdir"
  # Work advances on a different path (from the same base)
  (
    cd "$workdir"
    git remote add no-mistakes "$nm_dir"
    git fetch no-mistakes 2>/dev/null || true
    git reset --hard "$base_sha" 2>/dev/null || true
    printf '# work path\n' > work.txt
    git add work.txt
    git commit -qm "work path"
  )
  set +e
  out="$("$SCRIPT" "$workdir" 2>"$tmp/err")"
  rc=$?
  set -e
  [ "$out" = "diverged" ] || fail "diverged: expected 'diverged', got '$out' (exit=$rc, err=$(cat "$tmp/err"))"
  pass "4. diverged"
}

# --- 5. no no-mistakes remote --------------------------------------------

test_no_remote() {
  local gate_sha workdir="$tmp/work-noremote" nm_dir="$tmp/nm-noremote"
  gate_sha=$(mk_gate_work "$tmp/gate-noremote" "gate")
  mk_nm_remote "$nm_dir" "$gate_sha"
  # Workdir needs at least one commit for HEAD to resolve
  mk_workdir "$workdir"
  (
    cd "$workdir"
    printf '# work\n' > work.txt
    git add work.txt
    git commit -qm "work" 2>/dev/null || true
  )
  # No remote added - the workdir has no no-mistakes remote
  set +e
  out="$("$SCRIPT" "$workdir" 2>"$tmp/err")"
  rc=$?
  set -e
  [ "$rc" != 0 ] || fail "no-remote: expected non-zero exit, got: $out"
  grep -q "no-mistakes remote" "$tmp/err" \
    || fail "no-remote: missing error about no-mistakes remote"
  pass "5. no no-mistakes remote"
}

# --- 6. missing gate config ----------------------------------------------

test_missing_config() {
  local gate_sha workdir="$tmp/work-nogate" nm_dir="$tmp/nm-nogate"
  gate_sha=$(mk_gate_work "$tmp/gate-nogate" "gate")
  mkdir -p "$nm_dir"
  git init --bare -q "$nm_dir"
  # No gate config file
  mk_workdir "$workdir"
  (
    cd "$workdir"
    printf '# work\n' > work.txt
    git add work.txt
    git commit -qm "work" 2>/dev/null || true
    git remote add no-mistakes "$nm_dir"
  )
  set +e
  out="$("$SCRIPT" "$workdir" 2>"$tmp/err")"
  rc=$?
  set -e
  [ "$rc" != 0 ] || fail "no-config: expected non-zero exit, got: $out"
  grep -q "gate config not found" "$tmp/err" \
    || fail "no-config: missing error about gate config"
  pass "6. missing gate config"
}

# --- 7. bad gate config format -------------------------------------------

test_bad_config() {
  local gate_sha workdir="$tmp/work-badgate" nm_dir="$tmp/nm-badgate"
  gate_sha=$(mk_gate_work "$tmp/gate-badgate" "gate")
  mkdir -p "$nm_dir"
  git init --bare -q "$nm_dir"
  printf 'broken\n' > "$nm_dir/no-mistakes-gate-config"
  mk_workdir "$workdir"
  (
    cd "$workdir"
    printf '# work\n' > work.txt
    git add work.txt
    git commit -qm "work" 2>/dev/null || true
    git remote add no-mistakes "$nm_dir"
  )
  set +e
  out="$("$SCRIPT" "$workdir" 2>"$tmp/err")"
  rc=$?
  set -e
  [ "$rc" != 0 ] || fail "bad-config: expected non-zero exit, got: $out"
  grep -q "unexpected gate config format" "$tmp/err" \
    || fail "bad-config: missing format error"
  pass "7. bad gate config format"
}

# --- 8. nonexistent branch (when not passing a workdir) ------------------

test_bad_branch() {
  local gate_sha workdir="$tmp/work-nobranch" nm_dir="$tmp/nm-nobranch"
  gate_sha=$(mk_gate_work "$tmp/gate-nobranch" "gate")
  mk_nm_remote "$nm_dir" "$gate_sha"
  mk_workdir "$workdir"
  set +e
  out="$("$SCRIPT" "nonexistent-branch" 2>"$tmp/err")"
  rc=$?
  set -e
  [ "$rc" != 0 ] || fail "bad-branch: expected non-zero exit, got: $out"
  grep -q "does not exist" "$tmp/err" \
    || fail "bad-branch: missing branch-exists error"
  pass "8. nonexistent branch"
}

# --- 9. script parses under bash -n --------------------------------------

test_parses() {
  bash -n "$SCRIPT" || fail "bash -n failed on the script"
  pass "9. script parses under bash -n"
}

# --- 10. output is exactly one word, no trailing whitespace ---------------

test_output_clean() {
  for test_case in equal ahead behind diverged; do
    case "$test_case" in
      equal)
        local gate_dir="$tmp/work-clean-$test_case-g" nm_dir="$tmp/work-clean-$test_case-n"
        local workdir="$tmp/work-clean-$test_case-w" gate_sha
        gate_sha=$(mk_gate_work "$gate_dir" "gate")
        mk_nm_remote "$nm_dir" "$gate_sha"
        mk_workdir "$workdir"
        (
          cd "$workdir"
          git remote add no-mistakes "$nm_dir"
          git fetch "$gate_dir" "$gate_sha" 2>/dev/null || true
          git reset --hard "$gate_sha" 2>/dev/null || true
        )
        ;;
      ahead)
        local gate_dir="$tmp/work-clean-$test_case-g" nm_dir="$tmp/work-clean-$test_case-n"
        local workdir="$tmp/work-clean-$test_case-w" gate_sha
        gate_sha=$(mk_gate_work "$gate_dir" "gate")
        mk_nm_remote "$nm_dir" "$gate_sha"
        mk_workdir "$workdir"
        (
          cd "$workdir"
          git remote add no-mistakes "$nm_dir"
          git fetch "$gate_dir" "$gate_sha" 2>/dev/null || true
          git reset --hard "$gate_sha" 2>/dev/null || true
          printf '# work\n' > work.txt
          git add work.txt
          git commit -qm "work"
        )
        ;;
      behind)
        local gate_dir="$tmp/work-clean-$test_case-g" nm_dir="$tmp/work-clean-$test_case-n"
        local workdir="$tmp/work-clean-$test_case-w" base_sha gate_sha
        base_sha=$(mk_gate_work "$gate_dir" "base")
        (
          cd "$gate_dir"
          printf '# advance\n' > adv.txt
          git add adv.txt
          git commit -qm "advance"
        )
        gate_sha=$(git -C "$gate_dir" rev-parse HEAD)
        mk_nm_remote "$nm_dir" "$gate_sha"
        # Push gate commits to bare nm repo so ancestry checks work
        (
          cd "$gate_dir"
          git remote add nm "$nm_dir" 2>/dev/null || true
          git push nm master:master 2>/dev/null || true
        )
        mk_workdir "$workdir"
        (
          cd "$workdir"
          git remote add no-mistakes "$nm_dir"
          git fetch no-mistakes 2>/dev/null || true
          git reset --hard "$base_sha" 2>/dev/null || true
        )
        ;;
      diverged)
        local gate_dir="$tmp/work-clean-$test_case-g" nm_dir="$tmp/work-clean-$test_case-n"
        local workdir="$tmp/work-clean-$test_case-w" base_sha gate_sha
        base_sha=$(mk_gate_work "$gate_dir" "base")
        (
          cd "$gate_dir"
          printf '# gate\n' > gate.txt
          git add gate.txt
          git commit -qm "gate"
        )
        gate_sha=$(git -C "$gate_dir" rev-parse HEAD)
        mk_nm_remote "$nm_dir" "$gate_sha"
        # Push gate commits to bare nm repo so ancestry checks work
        (
          cd "$gate_dir"
          git remote add nm "$nm_dir" 2>/dev/null || true
          git push nm master:master 2>/dev/null || true
        )
        mk_workdir "$workdir"
        (
          cd "$workdir"
          git remote add no-mistakes "$nm_dir"
          git fetch no-mistakes 2>/dev/null || true
          git reset --hard "$base_sha" 2>/dev/null || true
          printf '# work\n' > work.txt
          git add work.txt
          git commit -qm "work"
        )
        ;;
    esac
    set +e
    out="$("$SCRIPT" "$workdir" 2>/dev/null)"
    rc=$?
    set -e
    # Verify output is exactly one of the four words
    case "$out" in
      equal|ahead|behind|diverged) ;;
      *) fail "clean-$test_case: unexpected output '$out' (exit=$rc)" ;;
    esac
    # Verify no trailing whitespace
    case "$out" in
      *" "*) fail "clean-$test_case: output has trailing whitespace" ;;
    esac
  done
  pass "10. output is clean single word"
}

# --- run all tests -------------------------------------------------------

test_parses
test_equal
test_ahead
test_behind
test_diverged
test_no_remote
test_missing_config
test_bad_config
test_bad_branch
test_output_clean

echo "ok: fm-nomistakes-gate-check.test.sh"
