#!/usr/bin/env python3
"""Verify the no-mistakes `review.path_instructions` "guard the bar" entries.

Independent oracle: no-mistakes resolves these globs with Go's path.Match
(strings lifted from the installed v1.106.1 binary: path.Match,
path/filepath.Match, and no doublestar matcher). Go's documented path.Match
semantics are: '*' matches any sequence of non-'/' characters, '?' any single
non-'/' character, and matching never crosses a '/'. That contract is
implemented here as an equivalent per-segment regex translation, so this script
is an independent model of the engine's matcher rather than a copy of the
config's own expectations.

Inputs:
  --config <git-rev|path>  config to test (default: HEAD's .no-mistakes.yaml)
  --tree   <git-rev>       commit whose tracked tree is the path universe
                           (default: same rev as --config when it is a rev)

Checks:
  C1 coverage    every tracked path under tests/, bin/, .github/workflows/ and
                 the tracked .no-mistakes.yaml resolves to a bar-lowering guard
                 rule (not merely to a pointer rule)
  C2 nested      the concrete nested paths named while fixing the guard scope
                 resolve to a guard rule
  C3 specificity no guard rule leaks onto paths outside the guarded trees
  C4 caps        entries <= 32 and path+instruction bytes <= 16384 (engine caps)
  C5 intent      each guard rule names every bar-lowering category the change
                 is meant to flag

Exit 0 when every check passes, 1 otherwise.
"""
import argparse
import os
import re
import subprocess
import sys

import yaml

REPO = "{run-worktree}"
GUARDED_TREES = ("tests/", "bin/", ".github/workflows/")
GUARDED_FILES = (".no-mistakes.yaml",)
ENTRY_CAP = 32
BYTE_CAP = 16384  # review.path_instructions prompt-budget cap (engine constant)
GUARD_MARKER = "lowers the bar"
POINTER_MARKER = ".agents/skills/"

NESTED_NAMED_PATHS = [
    "tests/captures/no-mistakes-v1.70.1/completed.toon",
    "tests/captures/no-mistakes-v1.70.1/same-branch-inventory.json",
    "tests/fixtures/opencode-1.18.31-cwd/opencode-1.18.31-idle-cwd.ansi",
    "tests/assets/board-render-harness.mjs",
    "tests/lib.sh",
    "bin/backends/herdr.sh",
    "bin/backends/tmux.sh",
    ".github/workflows/ci.yml",
    ".no-mistakes.yaml",
]

UNGUARDED_CONTROLS = [
    "docs/configuration.md",
    "README.md",
    "CONTRIBUTING.md",
    "VISION.md",
]

# Intent categories the guard text must name (user intent wording).
INTENT_CATEGORIES = {
    "deleted/skipped test": r"deleted,\s*\n?\s*skipped",
    "removed/weakened assertion": r"removed or weakened\s*\n?\s*assertion",
    "suppression comment": r"suppression",
    "stub/short-circuit": r"stub or short-circuit",
    "raised timeout/retry/tolerance": r"raised timeout, retry count, or tolerance",
    "narrowed test selection": r"narrowed test\s*\n?\s*selection",
}


def go_path_match(pattern: str, name: str) -> bool:
    """Go path.Match equivalent for the patterns this config uses."""
    if pattern == name:
        return True
    regex = []
    for ch in pattern:
        if ch == "*":
            regex.append("[^/]*")
        elif ch == "?":
            regex.append("[^/]")
        elif ch == "\\" and False:  # path.Match escapes are unused here
            continue
        else:
            regex.append(re.escape(ch))
    return re.fullmatch("".join(regex), name) is not None


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", REPO, *args],
        check=True,
        text=True,
        capture_output=True,
    ).stdout


def load_config(spec: str):
    if os.path.isfile(spec):
        with open(spec, encoding="utf-8") as fh:
            text = fh.read()
        label = spec
    else:
        text = git("show", f"{spec}:.no-mistakes.yaml")
        label = f"{spec}:.no-mistakes.yaml"
    data = yaml.safe_load(text)
    entries = ((data or {}).get("review") or {}).get("path_instructions") or []
    return label, [(e["path"], e["instructions"]) for e in entries]


def tracked_paths(rev: str):
    return [p for p in git("ls-tree", "-r", "--name-only", rev).splitlines() if p]


def kind(instructions: str) -> str:
    if GUARD_MARKER in instructions:
        return "guard"
    if POINTER_MARKER in instructions:
        return "pointer"
    return "other"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="HEAD")
    ap.add_argument("--tree", default=None)
    args = ap.parse_args()
    tree_rev = args.tree or (args.config if not os.path.isfile(args.config) else "HEAD")

    label, entries = load_config(args.config)
    paths = tracked_paths(tree_rev)
    guard = [(p, i) for p, i in entries if kind(i) == "guard"]

    def matches(path):
        return [p for p, i in entries if go_path_match(p, path)]

    def guard_matches(path):
        return [p for p, i in guard if go_path_match(p, path)]

    failures = []
    print(f"config: {label}   tree: {tree_rev}   tracked files: {len(paths)}")
    print(f"entries: {len(entries)} ({len(guard)} guard, {len(entries) - len(guard)} pointer/other)")
    print()
    print("guard globs (Go path.Match):")
    for p, _ in guard:
        print(f"  {p}")
    print()

    # C1 coverage
    guarded_universe = [
        p for p in paths if p.startswith(GUARDED_TREES) or p in GUARDED_FILES
    ]
    uncovered = [p for p in guarded_universe if not guard_matches(p)]
    print(f"[C1 coverage] {len(guarded_universe)} path(s) under tests/, bin/, "
          f".github/workflows/, plus .no-mistakes.yaml")
    if uncovered:
        failures.append(f"C1: {len(uncovered)} path(s) resolve to no guard rule")
        for p in uncovered[:25]:
            print(f"  MISS {p} -> {matches(p) or 'no rule at all'}")
        if len(uncovered) > 25:
            print(f"  ... {len(uncovered) - 25} more")
    else:
        print("  OK every guarded-tree path resolves to a bar-lowering guard rule")
    # depth histogram of the matched rule per path (shows per-depth coverage)
    per_rule = {}
    for p in guarded_universe:
        for g in guard_matches(p):
            per_rule.setdefault(g, 0)
            per_rule[g] += 1
    for g, n in sorted(per_rule.items()):
        print(f"  {g:<24} {n} file(s)")
    print()

    # C2 nested named paths
    print("[C2 nested paths] concrete paths from the accepted guard scope")
    tracked_set = set(paths)
    for p in NESTED_NAMED_PATHS:
        gm = guard_matches(p)
        exists = p in tracked_set
        status = "OK  " if (gm and (exists or p not in tracked_set)) else "MISS"
        if not gm:
            failures.append(f"C2: {p} resolves to no guard rule")
        print(f"  {status} {p:<58} -> {', '.join(gm) if gm else '(none)'}"
              f"{'' if exists else '   [not tracked; representative depth]'}")
    print()

    # C3 specificity
    print("[C3 specificity] paths outside the guarded trees must not match a guard rule")
    for p in UNGUARDED_CONTROLS:
        gm = guard_matches(p)
        if gm:
            failures.append(f"C3: {p} unexpectedly matches guard rule(s) {gm}")
            print(f"  LEAK {p} -> {', '.join(gm)}")
        else:
            print(f"  OK   {p:<24} -> guard rules: none; all rules: {', '.join(matches(p)) or 'none'}")
    print()

    # C4 caps
    bytes_total = sum(len(p.encode()) + len(i.encode()) for p, i in entries)
    print(f"[C4 caps] entries {len(entries)}/{ENTRY_CAP}, path+instruction bytes {bytes_total}/{BYTE_CAP}")
    if len(entries) > ENTRY_CAP:
        failures.append(f"C4: {len(entries)} entries exceeds cap {ENTRY_CAP}")
    if bytes_total > BYTE_CAP:
        failures.append(f"C4: {bytes_total} bytes exceeds budget {BYTE_CAP}")
    print()

    # C5 intent categories
    print("[C5 intent] every guard rule names each bar-lowering category")
    for p, i in guard:
        flat = " ".join(i.split())
        missing = [name for name, pat in INTENT_CATEGORIES.items()
                   if not re.search(pat, i) and not re.search(pat.replace(r"\s*\n?\s*", " "), flat)]
        if missing:
            failures.append(f"C5: guard rule {p} omits {missing}")
            print(f"  MISS {p}: {missing}")
        else:
            print(f"  OK   {p}")
    print()

    print("RESULT:", "PASS" if not failures else f"FAIL ({len(failures)} problem(s))")
    for f in failures:
        print("  -", f)
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
