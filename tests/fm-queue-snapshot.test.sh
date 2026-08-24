#!/usr/bin/env bash
# tests/fm-queue-snapshot.test.sh - behavior tests for bin/fm-queue-snapshot.sh.
# Exercises the helper only through its executable interface against a real
# tasks-axi backlog and a real data/projects.md registry: the derived
# autonomy label must match kind/hold-kind/yolo exactly, gated items must
# carry their blocked/held facts rather than being dropped, an unregistered
# project must default to captain-gated (never a guessed autonomous label),
# and dispatch_config must report the shared crew-dispatch validity verdict
# (absent/present/invalid/unverified) that bin/fm-crew-dispatch-lib.sh owns and
# bin/fm-bootstrap.sh reports as CREW_DISPATCH, so a config that parses as JSON
# but breaks the contract is never published as a usable tier source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-queue-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-queue-snapshot)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }

# Build an explicit PATH holding every tool the snapshot needs EXCEPT the named
# one, so "tool missing" is simulated additively. Subtracting the tool's
# directory from PATH would take its neighbours (python3, mktemp, awk...) with
# it wherever the tool shares a bin dir with coreutils.
path_without() {  # <tool-to-omit>
  local omit=$1 dir tool src
  dir="$TMP_ROOT/nopath-$omit"
  rm -rf "$dir"
  mkdir -p "$dir"
  for tool in awk basename bash cat cut dirname env grep head jq mktemp node paste \
    python3 rm sed sh tr tasks-axi uname wc quota-axi; do
    [ "$tool" = "$omit" ] && continue
    src=$(command -v "$tool" 2>/dev/null) || continue
    [ -n "$src" ] && ln -s "$src" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

# Writes a stub quota-axi into the given PATH-shim directory that reports one
# provider ("claude") at the given effective percent remaining for
# "all_models", so hierarchy availability tests never depend on the real
# account's live quota.
stub_quota_axi() {  # <dir> <percent-remaining>
  local dir=$1 pct=$2
  cat > "$dir/quota-axi" <<STUB
#!/usr/bin/env bash
cat <<JSON
{"providers":[{"provider":"claude","quotaSemantics":{"effectiveAvailability":[
  {"scope":"all_models","effectivePercentRemaining":$pct}
]}}]}
JSON
STUB
  chmod +x "$dir/quota-axi"
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

run_snapshot() {  # <home> [args...]
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$SNAPSHOT" "$@"
}

# 1. A ship item on a yolo=on project is autonomous-eligible; a captain-kind
#    item and a captain-kind hold are both captain-gated with the gate facts
#    (blocked/held/hold_reason) preserved rather than dropped from the row.
home=$(make_home basic)
printf '%s\n' '- demo-proj [direct-PR +yolo] - test project (added 2026-08-20)' > "$home/data/projects.md"
(
  cd "$home" || exit 1
  tasks-axi add demo-a "fix the thing" --kind ship --repo demo-proj --priority 2 >/dev/null
  tasks-axi add demo-b "captain decision on X" --kind captain --repo demo-proj >/dev/null
  tasks-axi add demo-c "blocked item" --kind ship --repo demo-proj --blocked-by demo-a >/dev/null
  tasks-axi hold demo-c --reason "waiting on demo-a" --kind captain >/dev/null
)
out=$(run_snapshot "$home")
case "$out" in
  *"count: 3"*) ;;
  *) fail "expected count: 3, got: $out" ;;
esac
case "$out" in
  *"demo-a,fix the thing,ship,demo-proj,2,no,none,no,-,-,-,direct-PR on,autonomous-eligible,"*) ;;
  *) fail "demo-a row not autonomous-eligible on yolo-on project: $out" ;;
esac
case "$out" in
  *"demo-b,captain decision on X,captain,demo-proj,-,no,none,no,-,-,-,direct-PR on,captain-gated,captain kind"*) ;;
  *) fail "demo-b row not captain-gated by kind: $out" ;;
esac
case "$out" in
  *"demo-c,blocked item,ship,demo-proj,-,yes,demo-a,yes,captain,waiting on demo-a,-,direct-PR on,captain-gated,captain kind"*) ;;
  *) fail "demo-c row missing gate facts or not captain-gated: $out" ;;
esac
case "$out" in
  *"dispatch_config: absent"*) ;;
  *) fail "expected dispatch_config: absent, got: $out" ;;
esac

# 2. A yolo=off project is captain-gated even for an ordinary ship item, and
#    an unregistered project defaults to captain-gated rather than an
#    unclear or optimistic guess.
home=$(make_home yolo-off)
printf '%s\n' '- other-proj - no yolo project (added 2026-08-20)' > "$home/data/projects.md"
(
  cd "$home" || exit 1
  tasks-axi add demo-e "no-yolo item" --kind ship --repo other-proj >/dev/null
  tasks-axi add demo-f "unregistered project item" --kind ship --repo ghost-proj >/dev/null
)
out=$(run_snapshot "$home")
case "$out" in
  *"demo-e,no-yolo item,ship,other-proj,-,no,none,no,-,-,-,no-mistakes off,captain-gated,project registry posture has yolo off"*) ;;
  *) fail "demo-e row not captain-gated on yolo-off project: $out" ;;
esac
case "$out" in
  *"demo-f,unregistered project item,ship,ghost-proj,-,no,none,no,-,-,-,no-mistakes off,captain-gated,project registry posture has yolo off"*) ;;
  *) fail "unregistered project did not default to captain-gated: $out" ;;
esac

# 3. An item with no project recorded is unclear, never guessed either way -
#    unless it carries a captain-kind signal, which is captain-gated on its
#    own regardless of whether a project is recorded.
home=$(make_home no-project)
: > "$home/data/projects.md"
(
  cd "$home" || exit 1
  tasks-axi add demo-d "no project item" --kind docs >/dev/null
  tasks-axi add demo-g "captain call with no project" --kind captain >/dev/null
  tasks-axi add demo-h "held for captain with no project" --kind docs >/dev/null
  tasks-axi hold demo-h --reason "needs a captain call" --kind captain >/dev/null
)
out=$(run_snapshot "$home")
case "$out" in
  *"demo-d,no project item,docs,-,-,no,none,no,-,-,-,n/a,unclear,no project recorded on this item"*) ;;
  *) fail "no-project item was not reported unclear: $out" ;;
esac
case "$out" in
  *"demo-g,captain call with no project,captain,-,-,no,none,no,-,-,-,n/a,captain-gated,captain kind or captain-kind hold"*) ;;
  *) fail "captain-kind item with no project was not captain-gated: $out" ;;
esac
case "$out" in
  *"demo-h,held for captain with no project,docs,-,-,no,none,yes,captain,needs a captain call,-,n/a,captain-gated,captain kind or captain-kind hold"*) ;;
  *) fail "captain-kind hold with no project was not captain-gated: $out" ;;
esac

# 4. --limit is honored and applied before enrichment.
home=$(make_home limit)
: > "$home/data/projects.md"
(
  cd "$home" || exit 1
  tasks-axi add lim-a "one" --kind docs >/dev/null
  tasks-axi add lim-b "two" --kind docs >/dev/null
  tasks-axi add lim-c "three" --kind docs >/dev/null
)
out=$(run_snapshot "$home" --limit 2)
case "$out" in
  *"count: 2"*) ;;
  *) fail "expected count: 2 under --limit 2, got: $out" ;;
esac
case "$out" in
  *lim-c*) fail "--limit 2 unexpectedly included a third item: $out" ;;
esac

# 5. dispatch_config reflects the shared crew-dispatch validity verdict for a
#    valid file and for one that is not even parseable JSON.
home=$(make_home dispatch-present)
: > "$home/data/projects.md"
printf '%s\n' '{"rules":[],"default":[{"harness":"codex"}]}' > "$home/config/crew-dispatch.json"
out=$(run_snapshot "$home")
if command -v jq >/dev/null 2>&1; then
  case "$out" in
    *"dispatch_config: present"*) ;;
    *) fail "expected dispatch_config: present, got: $out" ;;
  esac
else
  case "$out" in
    *"dispatch_config: unverified"*) ;;
    *) fail "expected dispatch_config: unverified without jq, got: $out" ;;
  esac
fi

home=$(make_home dispatch-invalid)
: > "$home/data/projects.md"
printf '%s\n' '{ not valid json' > "$home/config/crew-dispatch.json"
out=$(run_snapshot "$home")
case "$out" in
  *"dispatch_config: invalid"*) ;;
  *) fail "expected dispatch_config: invalid, got: $out" ;;
esac
nojq_path=$(path_without jq)
out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" PATH="$nojq_path" "$SNAPSHOT")
case "$out" in
  *"dispatch_config: invalid"*) ;;
  *) fail "malformed JSON was not invalid without jq: $out" ;;
esac

# A config that parses but cannot be checked against the contract because jq is
# missing is reported as unverified, never as a usable present.
home=$(make_home dispatch-unverified)
: > "$home/data/projects.md"
printf '%s\n' '{"rules":[],"default":[{"harness":"codex"}]}' > "$home/config/crew-dispatch.json"
out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" PATH="$nojq_path" "$SNAPSHOT")
case "$out" in
  *"dispatch_config: unverified"*) ;;
  *) fail "expected dispatch_config: unverified without jq, got: $out" ;;
esac

# 5b. A config that parses as JSON but breaks the crew-dispatch validity
#     contract (the same contract bin/fm-bootstrap.sh reports as
#     CREW_DISPATCH: invalid) is invalid here too, so the skill never matches
#     tiers against a config real dispatch would refuse.
if command -v jq >/dev/null 2>&1; then
  home=$(make_home dispatch-contract-empty-when)
  : > "$home/data/projects.md"
  printf '%s\n' '{"rules":[{"when":"","use":{"harness":"codex"}}]}' > "$home/config/crew-dispatch.json"
  out=$(run_snapshot "$home")
  case "$out" in
    *"dispatch_config: invalid"*) ;;
    *) fail "a rule with an empty when was not reported invalid: $out" ;;
  esac

  home=$(make_home dispatch-contract-empty-default)
  : > "$home/data/projects.md"
  printf '%s\n' '{"rules":[],"default":[]}' > "$home/config/crew-dispatch.json"
  out=$(run_snapshot "$home")
  case "$out" in
    *"dispatch_config: invalid"*) ;;
    *) fail "an empty default array was not reported invalid: $out" ;;
  esac

  home=$(make_home dispatch-contract-bad-harness)
  : > "$home/data/projects.md"
  printf '%s\n' '{"default":{"harness":"nope"}}' > "$home/config/crew-dispatch.json"
  out=$(run_snapshot "$home")
  case "$out" in
    *"dispatch_config: invalid"*) ;;
    *) fail "an unverified harness was not reported invalid: $out" ;;
  esac

  # And the bootstrap diagnostic that owns this contract agrees with the
  # snapshot on the very same file.
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  case "$out" in
    *"CREW_DISPATCH: invalid config/crew-dispatch.json - unverified harness: nope"*) ;;
    *) fail "bootstrap diagnostic disagreed with the snapshot verdict: $out" ;;
  esac
else
  # Without jq the contract cannot be evaluated, and the snapshot must say so
  # rather than claiming a valid config.
  home=$(make_home dispatch-unverified)
  : > "$home/data/projects.md"
  printf '%s\n' '{"rules":[],"default":[{"harness":"codex"}]}' > "$home/config/crew-dispatch.json"
  out=$(run_snapshot "$home")
  case "$out" in
    *"dispatch_config: unverified"*) ;;
    *) fail "expected dispatch_config: unverified without jq, got: $out" ;;
  esac
fi

# 6. An empty queue reports count: 0 rather than erroring.
home=$(make_home empty)
: > "$home/data/projects.md"
out=$(run_snapshot "$home")
case "$out" in
  *"count: 0"*) ;;
  *) fail "expected count: 0 for an empty queue, got: $out" ;;
esac

# 7. A missing tasks-axi on PATH fails loudly rather than reporting an empty queue.
home=$(make_home missing-tool)
: > "$home/data/projects.md"
filtered_path=$(path_without tasks-axi)
out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" PATH="$filtered_path" "$SNAPSHOT" 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "expected non-zero exit when tasks-axi is absent from PATH"
case "$out" in
  *"tasks-axi not found on PATH"*) ;;
  *) fail "missing loud tasks-axi-not-found message: $out" ;;
esac

# 8. The row parser indexes columns by the header tasks-axi prints, not by
#    fixed position, so an added base column cannot silently shift every value
#    (project, kind, and therefore the autonomy verdict) into the wrong field.
#    The stub speaks tasks-axi's documented list output contract.
stub_dir="$TMP_ROOT/stub-bin"
rm -rf "$stub_dir"
cp -r "$(path_without tasks-axi)" "$stub_dir"
cat > "$stub_dir/tasks-axi" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
count: 1
tasks[1]{id,state,epic,kind,repo,title,blocked,blocked_by,held,hold_kind,hold_reason,hold_until,priority}:
  shift-a,queued,none,ship,shift-proj,shifted item,no,none,no,"-","-","-","3"
help[1]:
  - Run `tasks-axi show <id>` for full notes on a task
OUT
STUB
chmod +x "$stub_dir/tasks-axi"
home=$(make_home header-indexed)
printf '%s\n' '- shift-proj [direct-PR +yolo] - test project (added 2026-08-20)' > "$home/data/projects.md"
out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" PATH="$stub_dir" "$SNAPSHOT")
case "$out" in
  *"shift-a,shifted item,ship,shift-proj,3,no,none,no,-,-,-,direct-PR on,autonomous-eligible,"*) ;;
  *) fail "an extra base column shifted the parsed fields: $out" ;;
esac

# 9. A warning on tasks-axi's stderr is not folded into the parsed listing.
#    The stub writes it BETWEEN two rows, so a merged-fd capture would end the
#    block early and report a short queue.
cat > "$stub_dir/tasks-axi" <<'STUB'
#!/usr/bin/env bash
echo "count: 2"
echo 'tasks[2]{id,state,kind,repo,title,blocked,blocked_by,held,hold_kind,hold_reason,hold_until,priority}:'
echo '  warn-a,queued,ship,warn-proj,first item,no,none,no,"-","-","-","-"'
echo "help[1]: warn: backlog cache rebuilt" >&2
echo '  warn-b,queued,ship,warn-proj,second item,no,none,no,"-","-","-","-"'
echo "help[1]:"
echo "  - Run \`tasks-axi show <id>\` for full notes on a task"
STUB
home=$(make_home stderr-noise)
printf '%s\n' '- warn-proj [direct-PR +yolo] - test project (added 2026-08-20)' > "$home/data/projects.md"
out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" PATH="$stub_dir" "$SNAPSHOT" 2>/dev/null)
case "$out" in
  *"count: 2"*) ;;
  *) fail "stderr noise changed the reported count: $out" ;;
esac
case "$out" in
  *warn-b*) ;;
  *) fail "stderr noise truncated the listing: $out" ;;
esac

# 10. A row tasks-axi counted but this parser could not read is a loud failure,
#     never a silently shorter queue that looks complete.
cat > "$stub_dir/tasks-axi" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
count: 2
tasks[2]{id,state,kind,repo,title,blocked,blocked_by,held,hold_kind,hold_reason,hold_until,priority}:
  drop-a,queued,ship,drop-proj,first item,no,none,no,"-","-","-","-"
  drop-b,queued,ship,drop-proj
help[1]:
  - Run `tasks-axi show <id>` for full notes on a task
OUT
STUB
home=$(make_home short-row)
: > "$home/data/projects.md"
out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" PATH="$stub_dir" "$SNAPSHOT" 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "expected non-zero exit when a counted row could not be parsed"
case "$out" in
  *"parsed 1 of tasks-axi's 2 queued items"*) ;;
  *) fail "missing loud short-queue message: $out" ;;
esac

# 11. tasks-axi renders rows in TOON, which escapes an embedded quote as \"
#     rather than doubling it. A title carrying both a quote and a comma must
#     not shift the later columns, or a captain-kind hold reads as no hold and
#     the item flips to "clears itself".
home=$(make_home quoted-title)
printf '%s\n' '- quote-proj [direct-PR +yolo] - test project (added 2026-08-20)' > "$home/data/projects.md"
(
  cd "$home" || exit 1
  tasks-axi add quote-a 'add "queue" skill, read-only' --kind ship --repo quote-proj >/dev/null
  tasks-axi hold quote-a --reason "needs a call" --kind captain >/dev/null
)
out=$(run_snapshot "$home")
case "$out" in
  *'yes,captain,needs a call,-,direct-PR on,captain-gated,captain kind or captain-kind hold'*) ;;
  *) fail "a quoted, comma-bearing title shifted the parsed columns: $out" ;;
esac
case "$out" in
  *'add ""queue"" skill, read-only'*) ;;
  *) fail "the quoted title was not preserved: $out" ;;
esac

# 12. tasks-axi accepts a tab inside a title (it only rejects line breaks), and
#     the snapshot decodes TOON's \t while parsing. The emitted row must write
#     it back as the literal two-character escape so each item stays exactly one
#     CSV line and the columns after it are not split by a stray control char.
home=$(make_home control-chars)
printf '%s\n' '- ctl-proj [direct-PR +yolo] - test project (added 2026-08-20)' > "$home/data/projects.md"
(
  cd "$home" || exit 1
  tasks-axi add ctl-a "$(printf 'tabbed\ttitle')" --kind ship --repo ctl-proj >/dev/null
)
out=$(run_snapshot "$home")
case "$out" in
  *'ctl-a,tabbed\ttitle,ship,ctl-proj,-,no,none,no,-,-,-,direct-PR on,autonomous-eligible,'*) ;;
  *) fail "a tab in the title was not written back as a literal escape: $out" ;;
esac
case "$out" in
  *$'\t'*) fail "a raw control character reached the emitted rows: $out" ;;
esac

# 13. Every line of the snapshot is LF-terminated: an item row must not carry a
#     trailing CR that a consumer splitting on newlines would read as part of
#     autonomy_reason. A literal backslash in a title is doubled, as documented.
home=$(make_home line-endings)
printf '%s\n' '- crlf-proj [direct-PR +yolo] - test project (added 2026-08-20)' > "$home/data/projects.md"
(
  cd "$home" || exit 1
  tasks-axi add crlf-a 'fix C:\path' --kind captain --repo crlf-proj >/dev/null
)
run_snapshot "$home" > "$TMP_ROOT/line-endings.out"
carriage=$(grep -c $'\r' "$TMP_ROOT/line-endings.out") || true
[ "$carriage" = 0 ] || fail "the snapshot emitted CR characters: $(cat -A "$TMP_ROOT/line-endings.out")"
last_field=$(grep ',crlf-a,' "$TMP_ROOT/line-endings.out" | sed 's/.*,//')
[ "$last_field" = "captain kind or captain-kind hold" ] \
  || fail "autonomy_reason was not the documented value: [$last_field]"
case "$(cat "$TMP_ROOT/line-endings.out")" in
  *'crlf-a,fix C:\\path,captain,crlf-proj'*) ;;
  *) fail "a literal backslash was not doubled as documented: $(cat "$TMP_ROOT/line-endings.out")" ;;
esac

# 14. Items are sorted by descending priority with rank starting at 1;
#     unset priority ("-") sorts last; equal-priority items keep tasks-axi's
#     own return order as the tiebreak. --limit is applied AFTER the sort, so
#     a high-priority item outside the first N in tasks-axi's raw order still
#     survives.
home=$(make_home priority-sort)
: > "$home/data/projects.md"
(
  cd "$home" || exit 1
  tasks-axi add pri-low "low" --kind docs --priority 0 >/dev/null
  tasks-axi add pri-tie-1 "tie one" --kind docs --priority 2 >/dev/null
  tasks-axi add pri-tie-2 "tie two" --kind docs --priority 2 >/dev/null
  tasks-axi add pri-none "unset" --kind docs >/dev/null
  tasks-axi add pri-high "high" --kind docs --priority 4 >/dev/null
)
out=$(run_snapshot "$home")
case "$out" in
  *"1,pri-high,high,docs,-,4,"*) ;;
  *) fail "highest priority did not rank 1: $out" ;;
esac
case "$out" in
  *"2,pri-tie-1,tie one,docs,-,2,"*) ;;
  *) fail "equal-priority items did not keep insertion order (tie-1 expected rank 2): $out" ;;
esac
case "$out" in
  *"3,pri-tie-2,tie two,docs,-,2,"*) ;;
  *) fail "equal-priority items did not keep insertion order (tie-2 expected rank 3): $out" ;;
esac
case "$out" in
  *"4,pri-low,low,docs,-,0,"*) ;;
  *) fail "explicit priority 0 did not outrank unset priority: $out" ;;
esac
case "$out" in
  *"5,pri-none,unset,docs,-,-,"*) ;;
  *) fail "unset priority did not sort last: $out" ;;
esac

home=$(make_home priority-limit)
: > "$home/data/projects.md"
(
  cd "$home" || exit 1
  tasks-axi add lim-low-1 "low 1" --kind docs --priority 0 >/dev/null
  tasks-axi add lim-low-2 "low 2" --kind docs --priority 0 >/dev/null
  tasks-axi add lim-high "high" --kind docs --priority 4 >/dev/null
)
out=$(run_snapshot "$home" --limit 1)
case "$out" in
  *"count: 1"*) ;;
  *) fail "expected count: 1 under --limit 1 after sorting, got: $out" ;;
esac
case "$out" in
  *"1,lim-high,high,docs"*) ;;
  *) fail "--limit did not keep the highest-priority item after sorting: $out" ;;
esac
case "$out" in
  *lim-low*) fail "--limit kept a lower-priority item once the highest was included: $out" ;;
esac

# 15. Missing crew-dispatch.json reports hierarchy_lanes as unavailable, tied
#     to the same dispatch_config verdict the item tiers already use, rather
#     than a second independent gating check.
home=$(make_home hierarchy-absent)
: > "$home/data/projects.md"
out=$(run_snapshot "$home")
case "$out" in
  *"hierarchy_lanes: unavailable (dispatch_config: absent)"*) ;;
  *) fail "expected hierarchy_lanes unavailable for absent config, got: $out" ;;
esac

# 16. A present crew-dispatch.json yields one hierarchy row per rule/default
#     profile, using the rule's own `when` text - never a hardcoded task-class
#     label - and a profile array yields one row per candidate rather than a
#     collapsed summary.
if command -v jq >/dev/null 2>&1; then
  home=$(make_home hierarchy-present)
  : > "$home/data/projects.md"
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{
  "rules": [
    { "when": "hard or ambiguous work", "use": [
        { "harness": "claude", "model": "claude-opus-5", "effort": "high" },
        { "harness": "codex", "model": "gpt-5.5", "effort": "high" }
      ], "why": "senior" }
  ],
  "default": [ { "harness": "claude", "model": "claude-sonnet-5", "effort": "medium" } ]
}
EOF
  stub_dir_q=$(path_without quota-axi)
  stub_quota_axi "$stub_dir_q" 62
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" PATH="$stub_dir_q" "$SNAPSHOT")
  case "$out" in
    *"hierarchy_lanes[3]{source,for,harness,model,effort,available,availability_reason}:"*) ;;
    *) fail "expected 3 hierarchy lane rows (2 rule candidates + 1 default), got: $out" ;;
  esac
  case "$out" in
    *"rule,hard or ambiguous work,claude,claude-opus-5,high,yes,62% remaining"*) ;;
    *) fail "missing/incorrect claude rule lane row: $out" ;;
  esac
  case "$out" in
    *"rule,hard or ambiguous work,codex,gpt-5.5,high,unknown,no live quota data for codex"*) ;;
    *) fail "codex lane (no quota evidence stubbed) was not reported unknown: $out" ;;
  esac
  case "$out" in
    *"default,default (no rule matched),claude,claude-sonnet-5,medium,yes,62% remaining"*) ;;
    *) fail "missing/incorrect default lane row: $out" ;;
  esac

  # An exhausted window (0% remaining) is reported unavailable, not silently
  # dropped from the listing.
  home=$(make_home hierarchy-exhausted)
  : > "$home/data/projects.md"
  printf '%s\n' '{"default":{"harness":"claude","effort":"low"}}' > "$home/config/crew-dispatch.json"
  stub_quota_axi "$stub_dir_q" 0
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" PATH="$stub_dir_q" "$SNAPSHOT")
  case "$out" in
    *"default,default (no rule matched),claude,-,low,no,0% remaining"*) ;;
    *) fail "an exhausted window was not reported unavailable: $out" ;;
  esac
fi

# 17. live_slots counts state/*.meta entries currently tracked in this home,
#     regardless of the queue's own contents.
home=$(make_home live-slots)
: > "$home/data/projects.md"
out=$(run_snapshot "$home")
case "$out" in
  *"live_slots: 0"*) ;;
  *) fail "expected live_slots: 0 with no tracked tasks, got: $out" ;;
esac
: > "$home/state/task-a.meta"
: > "$home/state/task-b.meta"
out=$(run_snapshot "$home")
case "$out" in
  *"live_slots: 2"*) ;;
  *) fail "expected live_slots: 2 with two tracked meta files, got: $out" ;;
esac

echo "PASS fm-queue-snapshot.test.sh"
