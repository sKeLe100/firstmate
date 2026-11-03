#!/usr/bin/env bash
# tests/fm-haiku-builder-example.test.sh - checks the example haiku-builder agent
# definition (section-5 item-4 acceptance): its frontmatter parses as YAML, it
# pins the Haiku model with the required tools, it wires the alarm hook to both
# events, every path its hooks reference exists in this repository, and its body
# states the four-line final-reply contract the coordinator relies on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

doc="$ROOT/docs/examples/claude-agents/haiku-builder.md"
[ -f "$doc" ] || fail "missing example agent definition: $doc"

if ! python3 - "$doc" "$ROOT" <<'PY'
import json, os, re, subprocess, sys

doc, root = sys.argv[1], sys.argv[2]
text = open(doc, encoding="utf-8").read()
match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
if not match:
    sys.exit("no frontmatter block at the top of the agent definition")
try:
    parsed = subprocess.run(
        ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.safe_load(STDIN.read))"],
        input=match.group(1),
        capture_output=True,
        text=True,
    )
except OSError as exc:
    sys.exit("could not run ruby to parse the agent frontmatter: %s" % exc)
if parsed.returncode != 0:
    sys.exit("frontmatter is not valid YAML: %s" % parsed.stderr.strip())
try:
    front = json.loads(parsed.stdout)
except ValueError as exc:
    sys.exit("frontmatter did not parse to a mapping: %s" % exc)
if not isinstance(front, dict):
    sys.exit("frontmatter does not parse to a mapping")

if front.get("name") != "haiku-builder":
    sys.exit("name must be haiku-builder, got %r" % front.get("name"))
if front.get("model") != "haiku":
    sys.exit("model must pin haiku, got %r" % front.get("model"))
if front.get("effort") != "xhigh":
    sys.exit("effort must be xhigh, got %r" % front.get("effort"))
tools = {t.strip() for t in str(front.get("tools", "")).split(",")}
for needed in ("Read", "Edit", "Write", "Bash", "Grep", "Glob"):
    if needed not in tools:
        sys.exit("tools must include %s, got %r" % (needed, sorted(tools)))

hooks = front.get("hooks") or {}
for event in ("PreToolUse", "PostToolUse"):
    entries = hooks.get(event) or []
    commands = [h.get("command", "") for e in entries for h in (e.get("hooks") or [])]
    if not commands:
        sys.exit("hooks must wire %s" % event)
    for command in commands:
        paths = re.findall(r"bin/[A-Za-z0-9_./-]+", command)
        if not paths:
            sys.exit("hook command names no bin/ script: %r" % command)
        for path in paths:
            if not os.path.isfile(os.path.join(root, path)):
                sys.exit("hook references a path that does not exist: %s" % path)
        if "fm-haiku-alarm-hook.sh" not in command:
            sys.exit("hook must run the alarm hook, got %r" % command)

body = text[match.end():]
for label in ("DONE:", "NEXT:", "FILES-TOUCHED:", "AC-STATUS:"):
    if label not in body:
        sys.exit("final-reply contract is missing the %s line" % label)
PY
then
  fail "example haiku-builder agent definition does not meet its contract"
fi
pass "example agent frontmatter parses and pins haiku, xhigh, and the required tools"
pass "example agent wires the alarm hook to PreToolUse and PostToolUse, with every referenced path present"
pass "example agent body states the DONE/NEXT/FILES-TOUCHED/AC-STATUS final-reply contract"
