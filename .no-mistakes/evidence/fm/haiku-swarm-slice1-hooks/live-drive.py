#!/usr/bin/env python3
"""Live driver for Haiku swarm slice 1.

Runs the real bin/fm-subagent-context.sh, bin/fm-haiku-alarm-hook.sh and
bin/fm-handoff-guard-hook.sh against disposable fixtures, through the same
stdin/stdout contract Claude Code uses, and prints a transcript.
"""
import json
import os
import shutil
import subprocess
import tempfile
import textwrap

ROOT = os.getcwd()
READER = os.path.join(ROOT, "bin/fm-subagent-context.sh")
ALARM = os.path.join(ROOT, "bin/fm-haiku-alarm-hook.sh")
GUARD = os.path.join(ROOT, "bin/fm-handoff-guard-hook.sh")
EXAMPLE = os.path.join(ROOT, "docs/examples/claude-agents/haiku-builder.md")

out = []


def say(text=""):
    print(text)
    out.append(text)


def section(name):
    say("\n" + "=" * 78)
    say(name)
    say("=" * 78)


def run(argv, stdin="", env=None, cwd=None):
    proc = subprocess.run(
        argv,
        input=stdin,
        capture_output=True,
        text=True,
        env=env,
        cwd=cwd,
    )
    return proc.returncode, proc.stdout, proc.stderr


def show(label, rc, stdout, stderr):
    say("-" * 78)
    say(label)
    say("exit=%d" % rc)
    say("stdout: %s" % (stdout.rstrip() if stdout.strip() else "<empty>"))
    say("stderr: %s" % (stderr.rstrip() if stderr.strip() else "<empty>"))
    return rc, stdout, stderr


tmp = tempfile.mkdtemp(prefix="fm-haiku-live.")
proj = os.path.join(tmp, "proj")
sub_dir = os.path.join(proj, "sess-live", "subagents")
os.makedirs(sub_dir)
main_transcript = os.path.join(proj, "main.jsonl")
open(main_transcript, "w").close()
checkpoint = os.path.join(tmp, "checkpoint.md")

try:
    # ------------------------------------------------------------------
    # 1. Subagent context reader
    # ------------------------------------------------------------------
    section("SCENARIO 1: subagent context reader reports the last assistant usage sum")
    sub = os.path.join(sub_dir, "agent-haiku1.jsonl")
    with open(sub, "w") as fh:
        fh.write(json.dumps({"type": "user", "message": {"content": "brief"}}) + "\n")
        for total in (10000, 50000):
            fh.write(json.dumps({
                "type": "assistant",
                "isSidechain": True,
                "message": {"model": "claude-haiku-4-5", "usage": {"input_tokens": total}},
            }) + "\n")
        fh.write(json.dumps({
            "type": "assistant",
            "isSidechain": True,
            "message": {
                "model": "claude-haiku-4-5",
                "usage": {
                    "input_tokens": 60000,
                    "cache_creation_input_tokens": 10000,
                    "cache_read_input_tokens": 20000,
                },
            },
        }) + "\n")
    say("fixture agent-haiku1.jsonl assistant totals: 10000, 50000, 60000+10000+20000")
    rc, stdout, stderr = run([READER, main_transcript, "sess-live", "haiku1"])
    show("bin/fm-subagent-context.sh <main> sess-live haiku1", rc, stdout, stderr)
    assert rc == 0 and stdout.strip() == "context_tokens=90000 agent=haiku1 model=claude-haiku-4-5"

    section("SCENARIO 2: missing subagent transcript exits 1 with one clear line")
    rc, stdout, stderr = run([READER, main_transcript, "sess-live", "absent"])
    show("bin/fm-subagent-context.sh <main> sess-live absent", rc, stdout, stderr)
    assert rc == 1 and len(stderr.strip().splitlines()) == 1 and "no subagent transcript" in stderr

    section("SCENARIO 3: crafted agent id cannot escape the subagents directory")
    escape = os.path.join(proj, "sess-live", "evil.jsonl")
    with open(escape, "w") as fh:
        fh.write(json.dumps({"type": "assistant", "message": {"usage": {"input_tokens": 999999}}}) + "\n")
    rc, stdout, stderr = run([READER, main_transcript, "sess-live", "../evil"])
    show("bin/fm-subagent-context.sh <main> sess-live ../evil", rc, stdout, stderr)
    assert rc == 2 and stdout == ""

    # ------------------------------------------------------------------
    # Alarm hook
    # ------------------------------------------------------------------
    def set_context(total):
        with open(sub, "w") as fh:
            fh.write(json.dumps({
                "type": "assistant",
                "message": {"model": "claude-haiku-4-5", "usage": {"input_tokens": total}},
            }) + "\n")

    def alarm(event, tool, tool_input, agent="haiku1", response=None):
        payload = {
            "session_id": "sess-live",
            "transcript_path": main_transcript,
            "cwd": tmp,
            "hook_event_name": event,
            "agent_id": agent,
            "agent_type": "haiku-builder",
            "tool_name": tool,
            "tool_input": tool_input,
        }
        if response is not None:
            payload["tool_response"] = response
        env = dict(os.environ, FM_CHECKPOINT_PATH=checkpoint)
        return run(["bash", ALARM], json.dumps(payload), env=env)

    section("SCENARIO 4: alarm threshold matrix (79,999 / 80,000 / 94,999 / 95,000 / checkpoint / no agent id)")
    set_context(79999)
    rc, stdout, stderr = alarm("PostToolUse", "Read", {"file_path": "x"})
    show("79,999 PostToolUse Read", rc, stdout, stderr)
    assert rc == 0 and stdout == ""

    set_context(80000)
    rc, stdout, stderr = alarm("PostToolUse", "Read", {"file_path": "x"})
    show("80,000 PostToolUse Read", rc, stdout, stderr)
    warn80 = json.loads(stdout)["hookSpecificOutput"]["additionalContext"]
    assert rc == 0 and warn80.startswith("Context ~80k of a 100k price line.")
    assert "Finish only the current AC step" in warn80
    assert "Open no new files" in warn80
    assert "DONE/NEXT/FILES-TOUCHED" in warn80

    set_context(94999)
    rc, stdout, stderr = alarm("PostToolUse", "Read", {"file_path": "x"})
    show("94,999 PostToolUse Read", rc, stdout, stderr)
    warn94 = json.loads(stdout)["hookSpecificOutput"]["additionalContext"]
    assert rc == 0 and warn94.startswith("Context ~94k")

    set_context(95000)
    rc, stdout, stderr = alarm("PreToolUse", "Bash", {"command": "ls"})
    show("95,000 PreToolUse Bash", rc, stdout, stderr)
    deny = json.loads(stdout)["hookSpecificOutput"]
    assert rc == 0 and deny["permissionDecision"] == "deny"
    assert checkpoint in deny["permissionDecisionReason"]

    rc, stdout, stderr = alarm("PreToolUse", "Write",
                               {"file_path": checkpoint, "content": "checkpoint"})
    show("95,000 PreToolUse Write to FM_CHECKPOINT_PATH", rc, stdout, stderr)
    assert rc == 0 and stdout == ""

    rc, stdout, stderr = alarm("PreToolUse", "Edit",
                               {"file_path": checkpoint + ".bak", "old_string": "a", "new_string": "b"})
    show("95,000 PreToolUse Edit to checkpoint.md.bak (near miss)", rc, stdout, stderr)
    assert rc == 0 and json.loads(stdout)["hookSpecificOutput"]["permissionDecision"] == "deny"

    rc, stdout, stderr = alarm("PreToolUse", "Bash", {"command": "ls"}, agent="")
    show("95,000 PreToolUse with no agent_id", rc, stdout, stderr)
    assert rc == 0 and stdout == ""

    section("SCENARIO 5: alarm PostToolUse adds the just-returned result estimate")
    set_context(79999)
    rc, stdout, stderr = alarm("PostToolUse", "Read", {"file_path": "x"}, response="a" * 6000)
    show("79,999 + 6,000-char tool_response", rc, stdout, stderr)
    warn = json.loads(stdout)["hookSpecificOutput"]["additionalContext"]
    assert warn.startswith("Context ~81k")

    section("SCENARIO 6: alarm on a missing transcript is a loud one-line diagnostic, not silence")
    payload = {
        "session_id": "sess-live",
        "transcript_path": main_transcript,
        "cwd": tmp,
        "hook_event_name": "PreToolUse",
        "agent_id": "never-written",
        "tool_name": "Bash",
        "tool_input": {"command": "ls"},
    }
    rc, stdout, stderr = run(["bash", ALARM], json.dumps(payload),
                             env=dict(os.environ, FM_CHECKPOINT_PATH=checkpoint))
    show("PreToolUse for a subagent with no transcript file", rc, stdout, stderr)
    assert rc == 0 and stdout == "" and len(stderr.strip().splitlines()) == 1
    assert "no subagent transcript" in stderr

    # ------------------------------------------------------------------
    # Handoff guard
    # ------------------------------------------------------------------
    work = os.path.join(tmp, "work")
    os.makedirs(os.path.join(work, "subdir"))
    with open(os.path.join(work, "small.txt"), "w") as fh:
        fh.write("small\n")
    with open(os.path.join(work, "big.txt"), "w") as fh:
        fh.write("\n".join("x" * 100 for _ in range(2000)))
    guard_log = os.path.join(tmp, "handoff.jsonl")

    def guard(prompt, subagent_type="haiku-builder", model=None, tool="Agent",
              log=guard_log, extra_env=None):
        tool_input = {"prompt": prompt}
        if subagent_type is not None:
            tool_input["subagent_type"] = subagent_type
        if model is not None:
            tool_input["model"] = model
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": tool,
            "tool_input": tool_input,
            "cwd": work,
        }
        env = dict(os.environ)
        env.pop("FM_HANDOFF_BUDGET", None)
        if log is not None:
            env["FM_HANDOFF_LOG"] = log
        if extra_env:
            env.update(extra_env)
        return run(["bash", GUARD], json.dumps(payload), env=env)

    def log_rows(path):
        if not os.path.exists(path):
            return []
        with open(path, encoding="utf-8") as fh:
            return [json.loads(line) for line in fh if line.strip()]

    section("SCENARIO 7: guard allows an under-budget haiku-builder launch")
    rc, stdout, stderr = guard("Slice one.\nFILES:\n- small.txt")
    show("haiku-builder prompt with FILES small.txt", rc, stdout, stderr)
    assert rc == 0 and stdout == ""
    rows = log_rows(guard_log)
    assert len(rows) == 1 and rows[0]["decision"] == "allow"

    section("SCENARIO 8: guard denies an over-budget launch and names the three biggest contributors")
    rc, stdout, stderr = guard("Slice two.\nFILES:\n- big.txt")
    show("haiku-builder prompt with FILES big.txt (default 70,000 budget)", rc, stdout, stderr)
    deny = json.loads(stdout)["hookSpecificOutput"]
    reason = deny["permissionDecisionReason"]
    assert rc == 0 and deny["permissionDecision"] == "deny"
    assert "over the 70000 budget" in reason and "file:big.txt" in reason
    biggest = reason.split("biggest parts:", 1)[1].split(". Split", 1)[0]
    assert biggest.count("~") == 3, reason
    rows = log_rows(guard_log)
    assert len(rows) == 2 and rows[-1]["decision"] == "deny"
    assert rows[-1]["estimate"] > rows[-1]["budget"]

    section("SCENARIO 9: FM_HANDOFF_BUDGET moves the same launch across the line")
    rc, stdout, stderr = guard("Slice two.\nFILES:\n- big.txt",
                               extra_env={"FM_HANDOFF_BUDGET": "200000"})
    show("same big.txt launch with FM_HANDOFF_BUDGET=200000", rc, stdout, stderr)
    assert rc == 0 and stdout == ""
    rc, stdout, stderr = guard("Slice one.\nFILES:\n- small.txt",
                               extra_env={"FM_HANDOFF_BUDGET": "100"})
    show("same small.txt launch with FM_HANDOFF_BUDGET=100", rc, stdout, stderr)
    assert rc == 0 and "over the 100 budget" in \
        json.loads(stdout)["hookSpecificOutput"]["permissionDecisionReason"]

    section("SCENARIO 10: guard denies missing FILES, directories, globs, and malformed ranges")
    cases = [
        ("no FILES block", "Slice four, no file list.", "no FILES: block"),
        ("empty FILES block", "Slice.\nFILES:", "no FILES: block"),
        ("directory with slash", "Slice.\nFILES:\n- subdir/", "directory, not a file"),
        ("directory without slash", "Slice.\nFILES:\n- subdir", "directory, not a file"),
        ("glob entry", "Slice.\nFILES:\n- *.txt", "glob, not a file"),
        ("incomplete range", "Slice.\nFILES:\n- big.txt:1-", "incomplete line range"),
        ("reversed range", "Slice.\nFILES:\n- big.txt:5-2", "invalid line range"),
    ]
    for name, prompt, expected in cases:
        rc, stdout, stderr = guard(prompt)
        show("deny case: %s" % name, rc, stdout, stderr)
        reason = json.loads(stdout)["hookSpecificOutput"]["permissionDecisionReason"]
        assert rc == 0 and expected in reason, (name, reason)

    section("SCENARIO 11: FILES formatting variants are still counted, never silently dropped")
    variant_log = os.path.join(tmp, "variants.jsonl")
    variants = [
        ("star bullet", "Slice.\nFILES:\n* big.txt"),
        ("plus bullet", "Slice.\nFILES:\n+ big.txt"),
        ("numbered bullet", "Slice.\nFILES:\n1. big.txt"),
        ("blank line before entry", "Slice.\nFILES:\n\n- big.txt"),
        ("blank line between entries", "Slice.\nFILES:\n- small.txt\n\n- big.txt"),
    ]
    for name, prompt in variants:
        rc, stdout, stderr = guard(prompt, log=variant_log)
        show("variant: %s" % name, rc, stdout, stderr)
        assert rc == 0 and json.loads(stdout)["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "file:big.txt" in json.loads(stdout)["hookSpecificOutput"]["permissionDecisionReason"]
    say("variant deny rows: %d" % len(log_rows(variant_log)))
    assert len(log_rows(variant_log)) == len(variants)

    section("SCENARIO 12: non-haiku and non-Agent calls pass untouched and log nothing")
    untouched_log = os.path.join(tmp, "untouched.jsonl")
    rc, stdout, stderr = guard("not a haiku launch", subagent_type="general-purpose",
                               model="sonnet", log=untouched_log)
    show("Agent general-purpose/sonnet with no FILES", rc, stdout, stderr)
    assert rc == 0 and stdout == ""
    rc, stdout, stderr = guard("echo hi", subagent_type=None, tool="Bash",
                               log=untouched_log)
    show("Bash tool call", rc, stdout, stderr)
    assert rc == 0 and stdout == ""
    rc, stdout, stderr = guard("Slice.\nFILES:\n- small.txt", subagent_type=None,
                               model="haiku", log=untouched_log)
    show("Agent model=haiku with no subagent_type (guarded, allowed)", rc, stdout, stderr)
    assert rc == 0 and stdout == ""
    rows = log_rows(untouched_log)
    say("log rows after two untouched calls and one guarded call: %d (%s)"
        % (len(rows), ",".join(r["decision"] for r in rows)))
    assert len(rows) == 1 and rows[0]["decision"] == "allow"

    section("SCENARIO 13: unreadable FILES entries and a failing log never fail open")
    if os.geteuid() == 0:
        say("SKIP: unreadable fixture needs a non-root user")
    else:
        secret = os.path.join(work, "secret.txt")
        with open(secret, "w") as fh:
            fh.write("s" * 500)
        os.chmod(secret, 0)
        try:
            unreadable_log = os.path.join(tmp, "unreadable.jsonl")
            rc, stdout, stderr = guard("Slice.\nFILES:\n- big.txt\n- secret.txt",
                                       log=unreadable_log)
            show("whole-file secret.txt is stat-sized; big.txt still forces the deny", rc, stdout, stderr)
            assert rc == 0 and json.loads(stdout)["hookSpecificOutput"]["permissionDecision"] == "deny"
            assert len(log_rows(unreadable_log)) == 1

            range_log = os.path.join(tmp, "unreadable-range.jsonl")
            rc, stdout, stderr = guard("Slice.\nFILES:\n- secret.txt:1-1", log=range_log)
            show("unreadable range secret.txt:1-1 is denied, not crashed", rc, stdout, stderr)
            reason = json.loads(stdout)["hookSpecificOutput"]["permissionDecisionReason"]
            assert rc == 0 and "cannot be read" in reason and "secret.txt:1-1" in reason
            assert "Traceback" not in stderr
            assert len(log_rows(range_log)) == 1
        finally:
            os.chmod(secret, 0o600)

        blocker = os.path.join(tmp, "blocker")
        with open(blocker, "w") as fh:
            fh.write("blocker\n")
        bad_log = os.path.join(blocker, "nested", "handoff.jsonl")
        rc, stdout, stderr = guard("Slice.\nFILES:\n- big.txt", log=bad_log)
        show("over-budget launch whose FM_HANDOFF_LOG cannot be created", rc, stdout, stderr)
        assert rc == 0
        assert json.loads(stdout)["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "could not append to FM_HANDOFF_LOG" in stderr

    section("SCENARIO 14: one JSONL row per guarded decision, in order")
    count_log = os.path.join(tmp, "count.jsonl")
    guard("Slice.\nFILES:\n- small.txt", log=count_log)
    guard("Slice.\nFILES:\n- big.txt", log=count_log)
    guard("Slice, no files.", log=count_log)
    guard("unchanged", subagent_type="general-purpose", model="sonnet", log=count_log)
    rows = log_rows(count_log)
    say("log rows: %d; decisions=%s" % (len(rows), ",".join(r["decision"] for r in rows)))
    say("row keys: %s" % sorted(rows[0].keys()))
    assert [r["decision"] for r in rows] == ["allow", "deny", "deny"]

    # ------------------------------------------------------------------
    # Example agent definition
    # ------------------------------------------------------------------
    section("SCENARIO 15: example haiku-builder definition parses and wires the alarm hook")
    text = open(EXAMPLE, encoding="utf-8").read()
    assert text.startswith("---\n")
    frontmatter = text.split("---\n", 2)[1]
    proc = subprocess.run(
        ["ruby", "-ryaml", "-rjson", "-e",
         "puts JSON.generate(YAML.safe_load(STDIN.read))"],
        input=frontmatter, capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stderr
    front = json.loads(proc.stdout)
    say("parsed frontmatter: %s" % json.dumps(front, indent=2, sort_keys=True))
    assert front["name"] == "haiku-builder"
    assert front["model"] == "haiku"
    assert front["effort"] == "xhigh"
    tools = {t.strip() for t in front["tools"].split(",")}
    assert {"Read", "Edit", "Write", "Bash", "Grep", "Glob"} <= tools
    for event in ("PostToolUse", "PreToolUse"):
        commands = [h["command"] for e in front["hooks"][event] for h in e["hooks"]]
        say("%s hook commands: %s" % (event, commands))
        assert commands and all("fm-haiku-alarm-hook.sh" in c for c in commands)
        for command in commands:
            script = command.split()[-1]
            assert os.path.isfile(os.path.join(ROOT, script)), script
    body = text.split("---\n", 2)[2]
    for label in ("DONE:", "NEXT:", "FILES-TOUCHED:", "AC-STATUS:"):
        assert label in body, label
    say("body final-reply contract: DONE / NEXT / FILES-TOUCHED / AC-STATUS present")
    say("small-context discipline: %s" % (
        "present" if "Open another file only when" in body and "Run tests quietly" in body else "MISSING"))

    say("\nALL LIVE SCENARIOS PASSED")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
