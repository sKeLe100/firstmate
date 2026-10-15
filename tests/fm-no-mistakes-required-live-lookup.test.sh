#!/usr/bin/env bash
# Regression tests for the required-check workflow's zero-input live PR lookup.
#
# The workflow must call the pinned shared action with no explicit PR inputs so
# the action reads body and head SHA from one live PR API response. This parses
# the workflow YAML into a semantic model, then runs the pinned verifier against
# a local PR API fixture whose live facts differ from the archived event payload
# (the edited-body / rerun case).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$(dirname "${BASH_SOURCE[0]}")/../.github/workflows/no-mistakes-required.yml"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required-live-lookup)
MODEL="$TMP_ROOT/model.json"
VERIFY="$TMP_ROOT/verify.py"
DRIVER="$TMP_ROOT/drive.py"

command -v curl >/dev/null 2>&1 || fail "curl is required to fetch the pinned shared action"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"

python3 - "$WORKFLOW" "$MODEL" <<'PY' || fail "could not model the workflow"
import json, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
job = wf["jobs"]["check"]
steps = job["steps"]
action = [s for s in steps if "require-no-mistakes" in str(s.get("uses", ""))]
json.dump({
    "permissions": wf.get("permissions"),
    "step_count": len(steps),
    "action_steps": len(action),
    "uses": action[0]["uses"] if action else "",
    "with": action[0].get("with") if action else None,
}, open(sys.argv[2], "w"))
PY

model_field() {
  python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))[sys.argv[2]]))' "$MODEL" "$1"
}

ACTION_REF=$(python3 -c 'import json,re,sys;print(json.load(open(sys.argv[1]))["uses"].split("@")[1].split()[0])' "$MODEL")
case "$ACTION_REF" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) fail "the shared action is not pinned to a commit: '$ACTION_REF'" ;;
esac
[ "${#ACTION_REF}" = 40 ] || fail "the shared action pin is not a full 40-hex commit: '$ACTION_REF'"

test_workflow_uses_zero_input_pinned_action() {
  [ "$(model_field step_count)" = 1 ] || fail "the job has extra steps (custom fetch?): $(model_field step_count) steps"
  [ "$(model_field action_steps)" = 1 ] || fail "expected exactly one shared-action step"
  [ "$(model_field with)" = null ] || fail "the action passes explicit inputs: $(model_field with)"
  pass "the workflow calls the pinned action once with no explicit PR inputs and no custom fetch"
}

test_permissions_allow_live_lookup_only() {
  [ "$(model_field permissions)" = '{"contents": "read", "pull-requests": "read"}' ] ||
    fail "permissions changed: $(model_field permissions)"
  pass "token permissions stay contents:read + pull-requests:read"
}

curl --fail --silent --show-error --location \
  "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
  > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
[ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"

# Drive the pinned verifier the way the zero-input action does: no PR_* inputs,
# facts come from the live API fixture, the event payload carries stale ones.
cat > "$DRIVER" <<'PY'
import http.server, json, os, subprocess, sys, tempfile, threading

verify = sys.argv[1]
cur, old = "b" * 40, "a" * 40
marker = "Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)"

def body(head, override=False):
    steps = [{"step": s, "status": "completed"} for s in ("review", "test", "document")]
    if override:
        steps[1]["override_reason"] = "Approved despite failing configured Test"
    att = json.dumps({"head_sha": head, "steps": steps})
    return marker + "\n<!-- no-mistakes-pipeline-attestation:v1 " + att + " -->"

class H(http.server.BaseHTTPRequestHandler):
    payload, status, paths = {}, 200, []
    def do_GET(self):
        H.paths.append(self.path)
        self.send_response(H.status)
        self.end_headers()
        self.wfile.write(json.dumps(H.payload).encode())
    def log_message(self, *a):
        pass

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
# name, live body, live head, event body, event head, api status, exit, message
cases = [
    ("live body bound to live head passes", body(cur), cur, body(cur), cur, 200, 0, "structurally compliant"),
    ("attestation for an older head than live is refused", body(old), cur, body(cur), cur, 200, 1, "does not match"),
    ("rerun of an old event judges the live pair, not the archived one", body(cur), cur, "old invalid body", old, 200, 0, "structurally compliant"),
    ("lookup failure fails closed despite a valid event payload", body(cur), cur, body(cur), cur, 403, 1, "Could not verify"),
    ("approved failed Test without recorded opt-in is refused", body(cur, True), cur, body(cur), cur, 200, 1, "without a recorded repository opt-in"),
]
bad = 0
with tempfile.TemporaryDirectory() as d:
    for name, lb, lh, eb, eh, st, want, msg in cases:
        H.payload, H.status, H.paths = {"body": lb, "head": {"sha": lh}}, st, []
        ev = os.path.join(d, "event.json")
        json.dump({"pull_request": {"number": 1, "body": eb, "head": {"sha": eh, "ref": "t"}, "user": {"login": "u"}}}, open(ev, "w"))
        env = {k: v for k, v in os.environ.items() if not k.startswith(("PR_", "NM_EXEMPT_")) and k != "GITHUB_OUTPUT"}
        env.update(GITHUB_TOKEN="fixture", GITHUB_REPOSITORY="fixture/repo", GITHUB_EVENT_PATH=ev,
                   GITHUB_API_URL="http://127.0.0.1:%d" % srv.server_port)
        r = subprocess.run(["python3", verify], env=env, text=True, capture_output=True)
        ok = r.returncode == want and msg in r.stdout + r.stderr and H.paths == ["/repos/fixture/repo/pulls/1"]
        print(("ok - " if ok else "not ok - ") + name)
        if not ok:
            bad += 1
            print("  exit=%s paths=%s\n%s%s" % (r.returncode, H.paths, r.stdout, r.stderr))
srv.shutdown()
sys.exit(1 if bad else 0)
PY

test_pinned_verifier_judges_live_body_and_head() {
  local output rc=0
  output=$(python3 "$DRIVER" "$VERIFY" 2>&1) || rc=$?
  printf '%s\n' "$output"
  expect_code 0 "$rc" "the pinned verifier did not judge the live body/head pair as expected"
  pass "the pinned verifier uses one live lookup and fails closed"
}

test_workflow_uses_zero_input_pinned_action
test_permissions_allow_live_lookup_only
test_pinned_verifier_judges_live_body_and_head
