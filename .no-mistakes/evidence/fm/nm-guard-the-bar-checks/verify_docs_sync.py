#!/usr/bin/env python3
"""Check docs/configuration.md's gate-defaults paragraph against .no-mistakes.yaml.

The doc is the owned contract (CONTRIBUTING.md names docs/configuration.md the
owner of the tracked gate defaults), so this parses the real config into a
semantic model and compares it with the glob list and claims the paragraph
makes. Exit 0 when they agree.

Checks:
  D1 every bar-lowering guard glob in the config is named in the paragraph
  D2 the paragraph names no guard glob the config does not define
  D3 the paragraph still describes the pointer entries as pointers
  D4 the paragraph does not claim glob recursion (the engine is Go path.Match)
"""
import re
import sys

import yaml

REPO = "{run-worktree}"
DOC = f"{REPO}/docs/configuration.md"
CONFIG = f"{REPO}/.no-mistakes.yaml"
GUARD_MARKER = "lowers the bar"

config = yaml.safe_load(open(CONFIG, encoding="utf-8"))
entries = config["review"]["path_instructions"]
guard = [e["path"] for e in entries if GUARD_MARKER in e["instructions"]]
pointer = [e["path"] for e in entries if GUARD_MARKER not in e["instructions"]]

doc = open(DOC, encoding="utf-8").read()
para = next(line for line in doc.splitlines()
            if "review.path_instructions" in line and "bar-lowering guard globs" in line)

named = set(re.findall(r"`([^`]+)`", para)) & (
    set(re.findall(r"`([^`]+)`", para)) - {"review.path_instructions"}
)
named_globs = {g for g in named if "*" in g or g == ".no-mistakes.yaml"}

failures = []
print(f"config guard globs : {guard}")
print(f"doc named globs    : {sorted(named_globs)}")

missing = [g for g in guard if g not in named_globs]
all_config_globs = set(guard) | set(pointer)
extra = [g for g in sorted(named_globs) if g not in all_config_globs]
if missing:
    failures.append(f"D1 doc omits guard glob(s) {missing}")
if extra:
    failures.append(f"D2 doc names glob(s) not in config {extra}")
print(f"[D1] guard globs named in doc: {'OK' if not missing else 'MISSING ' + str(missing)}")
print(f"[D2] doc globs defined in config: {'OK' if not extra else 'EXTRA ' + str(extra)}")

pointer_claim = ("point the Review step at the maintainability rules" in para
                 and all(g in para for g in pointer if g != "AGENTS.md"))
print(f"[D3] pointer entries still described as pointers: {'OK' if pointer_claim else 'STALE'}")
if not pointer_claim:
    failures.append("D3 doc no longer describes the pointer entries as pointers")

recurse_claim = "recurs" in para or "**" in para
print(f"[D4] no glob-recursion claim in doc: {'OK' if not recurse_claim else 'STALE'}")
if recurse_claim:
    failures.append("D4 doc claims glob recursion the engine does not implement")

print()
print("RESULT:", "PASS" if not failures else f"FAIL ({len(failures)} problem(s))")
for f in failures:
    print("  -", f)
sys.exit(0 if not failures else 1)
