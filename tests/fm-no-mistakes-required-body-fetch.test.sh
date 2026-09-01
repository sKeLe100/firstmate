#!/usr/bin/env bash
# End-to-end regression tests for the required-check workflow's PR-body fetch.
#
# Exercises the real run script extracted from .github/workflows/no-mistakes-required.yml
# against a stubbed `gh`, parses $GITHUB_OUTPUT with GitHub-runner heredoc semantics,
# and feeds the resolved body into the pinned shared verifier the workflow calls.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
WORKFLOW="$(dirname "${BASH_SOURCE[0]}")/../.github/workflows/no-mistakes-required.yml"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required-body-fetch)
VERIFY="$TMP_ROOT/verify.py"
FETCH="$TMP_ROOT/fetch-step.sh"
PARSER="$TMP_ROOT/parse-output.py"
HEAD_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

COMPLIANT_BODY="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$HEAD_SHA\",\"steps\":$COMPLETED_STEPS} -->"

command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"

curl --fail --silent --show-error --location \
  "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
  > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
[ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"

# Semantic extraction: parse the workflow YAML and pull out the fetch step's run
# script and the action step's input mapping, rather than grepping the file.
python3 - "$WORKFLOW" "$FETCH" "$TMP_ROOT/with.json" <<'PY' || fail "could not extract the workflow steps"
import json, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = wf["jobs"]["check"]["steps"]
fetch = next(s for s in steps if s.get("id") == "pr")
action = next(s for s in steps if "require-no-mistakes" in str(s.get("uses", "")))
open(sys.argv[2], "w").write(fetch["run"])
json.dump(action["with"], open(sys.argv[3], "w"))
PY

# The action's pr-body input must be wired to the fetched output, not event context.
PR_BODY_INPUT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pr-body"])' "$TMP_ROOT/with.json")

# Emulate the runner's $GITHUB_OUTPUT parser: `value` prints the body output,
# `count` prints how many step outputs the runner would parse out of the file.
cat > "$PARSER" <<'PY'
import sys

mode, path = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
out, count, i = {}, 0, 0
while i < len(lines):
    line = lines[i]
    if "<<" in line:
        name, delim = line.split("<<", 1)
        count += 1
        i += 1
        buf = []
        while i < len(lines) and lines[i] != delim:
            buf.append(lines[i])
            i += 1
        out[name] = "\n".join(buf)
    elif "=" in line:
        count += 1
    i += 1
if mode == "count":
    print(count)
else:
    sys.stdout.write(out.get("body", ""))
PY

# Run the workflow's real fetch step with `gh` stubbed to return $1 as the PR body.
run_fetch_step() {
  local body=$1 dir=${2:-}
  [ -n "$dir" ] || dir=$(mktemp -d "$TMP_ROOT/run.XXXXXX")
  # shellcheck disable=SC2016 # the stub script must expand $STUB_BODY_FILE at run time
  printf '%s\n' '#!/usr/bin/env bash' 'cat "$STUB_BODY_FILE"' > "$dir/gh"
  chmod +x "$dir/gh"
  printf '%s\n' "$body" > "$dir/body.txt" # gh prints a trailing newline
  STUB_BODY_FILE="$dir/body.txt" PATH="$dir:$PATH" \
    GITHUB_OUTPUT="$dir/output.txt" PR_NUMBER=3007 REPO=example/repo \
    bash "$FETCH" >/dev/null || fail "the workflow fetch step failed"
  python3 "$PARSER" value "$dir/output.txt"
}

# Run the pinned verifier the way the composite action does, with a synchronize
# event payload that omits pull_request.body (the reported root cause).
run_verifier() {
  local pr_body=$1 dir
  dir=$(mktemp -d "$TMP_ROOT/verify.XXXXXX")
  cat > "$dir/event.json" <<EOF
{"pull_request": {"number": 3007, "head": {"sha": "$HEAD_SHA", "ref": "fm/x"}, "user": {"login": "regression"}}}
EOF
  GITHUB_EVENT_PATH="$dir/event.json" PR_BODY="$pr_body" PR_HEAD_SHA="$HEAD_SHA" \
    PR_HEAD_REF=fm/x PR_AUTHOR=regression PR_NUMBER=3007 python3 "$VERIFY" 2>&1
}

test_pr_body_input_is_wired_to_the_fetch_step() {
  # shellcheck disable=SC2016 # comparing against the literal workflow expression
  [ "$PR_BODY_INPUT" = '${{ steps.pr.outputs.body }}' ] ||
    fail "pr-body is wired to '$PR_BODY_INPUT', not the API-fetched step output"
  pass "the action's pr-body input consumes the API-fetched body"
}

test_synchronize_without_event_body_fails_without_the_fix() {
  local output rc=0
  output=$(run_verifier "") || rc=$?
  [ "$rc" -ne 0 ] || fail "verifier passed with no body; the regression is not reproducible"
  pass "reproduced: a synchronize payload with no pull_request.body fails the gate"
}

test_fetched_body_passes_the_gate_on_synchronize() {
  local body output rc=0
  body=$(run_fetch_step "$COMPLIANT_BODY")
  [ "$body" = "$COMPLIANT_BODY" ] || fail "fetched body did not round-trip through GITHUB_OUTPUT"
  output=$(run_verifier "$body") || rc=$?
  expect_code 0 "$rc" "the API-fetched body still failed the gate on a synchronize event"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "verifier did not report the fetched body as compliant"
  pass "the API-fetched body clears the gate when the event payload omits it"
}

test_body_cannot_escape_its_output_heredoc() {
  local hostile body keys dir
  dir=$(mktemp -d "$TMP_ROOT/run.XXXXXX")
  hostile="junk
__NM_PR_BODY__
body<<X
$COMPLIANT_BODY
X"
  body=$(run_fetch_step "$hostile" "$dir")
  [ "$body" = "$hostile" ] || fail "a hostile PR body escaped its GITHUB_OUTPUT heredoc: got [$body]"
  keys=$(python3 "$PARSER" count "$dir/output.txt")
  [ "$keys" = 1 ] || fail "the hostile body produced $keys step outputs instead of 1"
  pass "a body carrying the old fixed delimiter and forged output lines stays one opaque value"
}

test_noncompliant_fetched_body_still_fails_the_gate() {
  local body output rc=0
  body=$(run_fetch_step "some ordinary PR description
__NM_PR_BODY__
no signature here")
  output=$(run_verifier "$body") || rc=$?
  [ "$rc" -ne 0 ] || fail "a PR body with no no-mistakes signature passed the gate"
  pass "a non-compliant fetched body is still rejected by the gate"
}

test_pr_body_input_is_wired_to_the_fetch_step
test_synchronize_without_event_body_fails_without_the_fix
test_fetched_body_passes_the_gate_on_synchronize
test_body_cannot_escape_its_output_heredoc
test_noncompliant_fetched_body_still_fails_the_gate
