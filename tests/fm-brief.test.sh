#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug. The macos-stock-bash
# CI job that used to run `/bin/bash -n` under 3.2.57 was removed 2026-08-24
# (captain ruling: no Apple hardware - the removal stands on hardware absence,
# not runner cost), so no Bash 3.2 parse coverage exists anywhere right now and
# test_no_heredoc_in_command_substitution is the only guard left. Restore that job if Apple support matters again.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own, and since the macos-stock-bash CI job was removed
# 2026-08-24 nothing exercises Bash 3.2 - test_no_heredoc_in_command_substitution
# is the remaining structural guard.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode. fm-brief.sh no longer reads it -
# the ship mode arrives as an explicit flag - so this fixture exists to prove the
# scaffold ignores the registered posture (test_ship_mode_is_explicit_not_registry).
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id mode brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_mode in "brief-nomistakes-a1:no-mistakes" "brief-directpr-a2:direct-PR" "brief-localonly-a3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id --mode $mode should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    grep -qx "Delivery contract: mode=$mode" "$brief" \
      || fail "$id: brief did not record its machine-readable delivery contract line"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "{FIRSTMATE_SPEC}" "$brief" "$id: brief missing the {FIRSTMATE_SPEC} placeholder"
    assert_grep "## Captain's intent" "$brief" "$id: brief missing Captain's intent subsection"
    assert_grep "## Firstmate spec" "$brief" "$id: brief missing Firstmate spec subsection"
    assert_grep 'never a bare number such as "PR 108"' "$brief" "$id: brief missing the full-PR-URL rule"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# A ship task's delivery mode is firstmate's per-task decision, so a missing or
# unusable value must stop the scaffold instead of silently defaulting. The
# no-mistakes-prod-only row is the conditional registry policy: it is never a task
# mode, and its refusal must say to classify the task's surface first.
test_ship_mode_is_required_and_closed_set() {
  local home id out status label flag expect
  home="$TMP_ROOT/mode-required-home"
  mkdir -p "$home/data"
  id=0
  while IFS='|' read -r label flag expect; do
    [ -n "$label" ] || continue
    id=$((id + 1))
    # shellcheck disable=SC2086  # flag is an intentional word-split arg list (may be empty)
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "brief-required-$id" some-proj $flag 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/data/brief-required-$id/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
missing --mode||ship briefs require --mode
empty --mode value|--mode|requires a value
unknown mode value|--mode nope|must be one of no-mistakes, direct-PR, local-only
conditional policy is not a task mode|--mode no-mistakes-prod-only|classify this task's surface
ROWS
  pass "fm-brief.sh: ship --mode is required and closed-set validated"
}

# The registry is the captain's standing posture, not this task's answer: the
# scaffold must follow the explicit flag even when the project is registered
# with a different mode, and must not consult the registry at all.
test_ship_mode_is_explicit_not_registry() {
  local home brief
  home="$TMP_ROOT/explicit-over-registry-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a5 direct-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "explicit no-mistakes brief on a direct-PR project should scaffold"
  brief="$home/data/brief-explicit-a5/brief.md"
  grep -qx "Delivery contract: mode=no-mistakes" "$brief" \
    || fail "registered direct-PR posture overrode the explicit --mode"
  assert_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
    "explicit no-mistakes brief did not render the pipeline definition of done"

  # An unregistered project is not a blocker either, because nothing is looked up.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a6 never-registered --mode local-only >/dev/null 2>&1 \
    || fail "unregistered project should still scaffold from the explicit mode"
  grep -qx "Delivery contract: mode=local-only" "$home/data/brief-explicit-a6/brief.md" \
    || fail "unregistered project did not honour the explicit --mode"
  pass "fm-brief.sh: the explicit ship mode wins over the registered posture"
}

# yolo is firstmate's merge authority and never reaches the worker, and a scout
# or charter carries no delivery contract. Each must refuse rather than accept and
# discard the flag, which would look recorded but change nothing.
test_delivery_flags_are_refused_where_they_do_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/refused-flags-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
yolo on a ship brief|brief-refused-b1 some-proj --mode direct-PR --yolo on|--yolo is not a brief input
yolo=value form on a ship brief|brief-refused-b2 some-proj --mode direct-PR --yolo=off|--yolo is not a brief input
mode on a scout brief|brief-refused-b3 some-proj --scout --mode direct-PR|--mode applies only to ship briefs
mode on a secondmate charter|brief-refused-b4 --secondmate --no-projects --mode no-mistakes|--mode applies only to ship briefs
ROWS
  pass "fm-brief.sh: --yolo and scout/secondmate --mode are refused, never silently dropped"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  assert_no_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$brief" \
    "no-mistakes DOD must require --intent to be the Captain's intent subsection"
  assert_grep "plus any later words the captain actually said" "$brief" \
    "no-mistakes DOD must allow later captain words in --intent"
  assert_grep "Do not include \`## Firstmate spec\`" "$brief" \
    "no-mistakes DOD must keep Firstmate spec out of --intent"
  assert_grep "or your own decisions and tradeoffs" "$brief" \
    "no-mistakes DOD must keep worker tradeoffs out of --intent"
  assert_grep "This replaces the no-mistakes skill's advice to enrich \`--intent\`" "$brief" \
    "no-mistakes DOD must override the external skill's enrich-with-decisions guidance"

  # The --yes ban is a fleet-wide prohibition, not a preference, and it must not
  # claim an enforcement the tool does not provide: this is instruction only.
  assert_grep "NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide." "$brief" \
    "no-mistakes DOD must state the --yes ban as a prohibition"
  assert_grep "answering your own ask-user finding is a hard rule violation" "$brief" \
    "no-mistakes DOD must say why --yes is banned"
  assert_no_grep "Avoid \`--yes\`" "$brief" \
    "no-mistakes DOD still states the --yes ban as a preference"
  assert_no_grep "no-mistakes refuses" "$brief" \
    "no-mistakes DOD must not claim the tool itself refuses --yes"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose and bans --yes outright"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_perspective_flag_inserts_catalog_fragment_and_marker() {
  local home brief out rc
  home="$TMP_ROOT/perspective-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-persp-scout firstmate --scout --perspective explorer >/dev/null 2>&1 \
    || fail "scout --perspective explorer refused"
  brief="$home/data/brief-persp-scout/brief.md"
  assert_grep "Perspective: explorer" "$brief" "scout brief lacks the machine-readable Perspective: line"
  assert_grep "Stance: read-only repository discovery for one precise question." "$brief" \
    "scout brief lacks the explorer fragment body"
  # Section order: # Task, then # Perspective, then # Setup.
  awk '/^# Task$/{t=NR} /^# Perspective$/{p=NR} /^# Setup$/{s=NR} END{exit !(t && p && s && t<p && p<s)}' "$brief" \
    || fail "Perspective section is not between # Task and # Setup"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-persp-ship firstmate --mode no-mistakes --perspective validator 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "ship --perspective validator refused: $out"
  printf '%s' "$out" | grep -F "warning: --perspective on a ship brief" >/dev/null || fail "ship perspective warning missing: $out"
  brief="$home/data/brief-persp-ship/brief.md"
  assert_grep "Perspective: validator" "$brief" "ship brief lacks the Perspective: line"
  assert_grep "Delivery contract: mode=no-mistakes" "$brief" "ship brief with a perspective lost its delivery contract"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-persp-none firstmate --scout >/dev/null 2>&1
  assert_no_grep "# Perspective" "$home/data/brief-persp-none/brief.md" "brief without --perspective carries a Perspective section"
  pass "fm-brief.sh: --perspective inserts the catalog fragment between Task and Setup with its marker"
}

test_perspective_flag_refuses_unknown_or_unsafe_slug() {
  local home out rc
  home="$TMP_ROOT/perspective-refuse-home"
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-persp-bad firstmate --scout --perspective no-such-slug 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unknown perspective slug was accepted"
  printf '%s' "$out" | grep -F "unknown perspective 'no-such-slug'" >/dev/null || fail "unknown slug error missing: $out"
  assert_absent "$home/data/brief-persp-bad/brief.md" "brief was written despite an unknown slug"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-persp-path firstmate --scout --perspective '../explorer' 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "path-like perspective slug was accepted"
  printf '%s' "$out" | grep -F "lowercase letters, digits, and dashes" >/dev/null || fail "unsafe slug error missing: $out"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-persp-empty firstmate --scout --perspective= 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "empty perspective slug was accepted"
  printf '%s' "$out" | grep -F "lowercase letters, digits, and dashes" >/dev/null || fail "empty slug error missing: $out"
  assert_absent "$home/data/brief-persp-empty/brief.md" "brief was written despite an empty slug"
  out=$(FM_HOME="$home" FM_SECONDMATE_CHARTER=x "$ROOT/bin/fm-brief.sh" brief-persp-sm --secondmate --no-projects --perspective explorer 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "--perspective accepted on a secondmate charter"
  printf '%s' "$out" | grep -F "applies only to crewmate ship or scout briefs" >/dev/null || fail "secondmate refusal missing: $out"
  pass "fm-brief.sh: --perspective refuses unknown, empty, unsafe, and charter-scoped slugs"
}

test_perspective_strip_keeps_prose_around_comments() {
  local home root brief
  home="$TMP_ROOT/perspective-strip-home"
  root="$TMP_ROOT/perspective-strip-root"
  mkdir -p "$home/data" "$root/.agents/skills/perspective-catalog/references"
  cat >"$root/.agents/skills/perspective-catalog/references/probe.md" <<'FRAG'
<!-- why (2026-09-04): maintainer bookkeeping that must not reach the worker. -->
Stance: probe stance line.
Refuse: fixing defects. <!-- why: ported from the pt-tracker seat. -->
FRAG
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-persp-strip firstmate --scout --perspective probe >/dev/null 2>&1 \
    || fail "scout --perspective probe was refused"
  brief="$home/data/brief-persp-strip/brief.md"
  assert_grep "Stance: probe stance line." "$brief" "brief dropped a plain fragment line"
  assert_grep "Refuse: fixing defects." "$brief" "brief dropped prose sharing a line with a trailing comment"
  assert_no_grep "maintainer bookkeeping" "$brief" "brief leaked the whole-line maintainer comment"
  assert_no_grep "pt-tracker seat" "$brief" "brief leaked a trailing maintainer comment"
  assert_no_grep '<!--' "$brief" "brief leaked an HTML comment marker"
  pass "fm-brief.sh: --perspective strips HTML comments and keeps the prose around them"
}

test_perspective_catalog_fragments_stay_within_bounds() {
  local dir home n slug brief
  dir="$ROOT/.agents/skills/perspective-catalog/references"
  home="$TMP_ROOT/perspective-catalog-home"
  mkdir -p "$home/data"
  n=$(find "$dir" -name '*.md' | wc -l | tr -d ' ')
  [ "$n" -le 7 ] || fail "perspective catalog grew past 7 entries ($n)"
  for f in "$dir"/*.md; do
    slug=$(basename "$f" .md)
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "brief-persp-$slug" firstmate --scout --perspective "$slug" >/dev/null 2>&1 \
      || fail "scout --perspective $slug was refused"
    brief="$home/data/brief-persp-$slug/brief.md"
    assert_present "$brief" "no brief was scaffolded for perspective $slug"
    assert_grep "Perspective: $slug" "$brief" "brief for $slug lacks its Perspective marker"
    grep -E '^<!-- why \([0-9]{4}-[0-9]{2}-[0-9]{2}\):' "$f" >/dev/null \
      || fail "catalog fragment $slug carries no dated why comment"
    assert_no_grep '<!--' "$brief" "brief for $slug leaked a maintainer HTML comment"
  done
  pass "perspective-catalog: every catalog slug renders a bounded, dated brief"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

# Regression (issue #2575): AGENTS.md section 11 and this script's own help tell
# firstmate to fill `{TASK}` and `{FIRSTMATE_SPEC}`. The unguarded Herdr gate used
# to quote `{TASK}` in its own prose, so that documented global replace spliced
# the whole task body into the middle of the gate's sentence - silently
# destroying the one contract that exists precisely because the scaffold cannot
# see the task text. Each placeholder must exist only at its genuine fill site,
# so the documented fill leaves the gate intact and each body appears once.
test_documented_global_replace_leaves_the_herdr_gate_intact() {
  local home id brief kind count content filled body spec
  home="$TMP_ROOT/task-fill-site-home"
  mkdir -p "$home/data"
  body='Restart the herdr session, then profile it'
  spec='Use the isolated lab helper for every lifecycle call'
  for kind in ship scout; do
    id="brief-fill-site-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind brief was not scaffolded"
    count=$(grep -c -F '{TASK}' "$brief")
    [ "$count" = 1 ] \
      || fail "$kind brief must carry exactly one {TASK} fill site, found $count"
    count=$(grep -c -F '{FIRSTMATE_SPEC}' "$brief")
    [ "$count" = 1 ] \
      || fail "$kind brief must carry exactly one {FIRSTMATE_SPEC} fill site, found $count"
    content=$(cat "$brief")
    filled=${content//'{TASK}'/$body}
    filled=${filled//'{FIRSTMATE_SPEC}'/$spec}
    count=$(printf '%s\n' "$filled" | grep -c -F "$body")
    [ "$count" = 1 ] \
      || fail "$kind brief: the documented {TASK} replace duplicated the intent body $count times"
    count=$(printf '%s\n' "$filled" | grep -c -F "$spec")
    [ "$count" = 1 ] \
      || fail "$kind brief: the {FIRSTMATE_SPEC} replace duplicated the spec body $count times"
    printf '%s\n' "$filled" | grep -qF 'this scaffold cannot inspect the task text' \
      || fail "$kind brief: the Herdr safety gate did not survive the documented fill"
  done
  pass "fm-brief.sh: the documented {TASK} and {FIRSTMATE_SPEC} fills cannot corrupt the Herdr safety gate"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep '# The captain and the parent channel' "$brief" \
    "secondmate charter lost the parent-channel section"
  assert_grep 'Nobody reads this chat' "$brief" \
    "secondmate charter no longer says the chat is unread"
  assert_grep 'in this home it IS the captain' "$brief" \
    "secondmate charter no longer names the parent channel as the captain"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, work ready for review, or work you landed' "$brief" \
    "secondmate charter lost decisions, blockers, failures, ready outcomes, or landed work"
  # Under standing merge authority nothing is ever "ready for review", so the
  # landed merge is the trigger a charter without this line silently omits.
  assert_grep 'a merge you performed yourself under standing merge authority and one the captain merged on the forge' "$brief" \
    "secondmate charter did not name a landed merge as a reporting trigger"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'a blocker or wait clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
    assert_grep 'even when the answer is what started that work' "$brief" \
      "$kind brief did not warn that an answer-started done/working never closes a decision"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the captain-call policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`captain-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared captain-call policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Regression for the field defect (2026-08-16, hit twice): a crewmate wrote
# needs-decision: [key=<slug>] ... (the token AFTER the colon), which
# bin/fm-classify-lib.sh's documented grammar folds under the bare "default"
# key rather than the intended slug, breaking --resolve-key targeting. Rule 6
# previously showed no example of the key syntax at all when opening a
# decision, only when closing one, so a crewmate had nothing correct to copy.
# This pins that both the ship and scout scaffolds now teach the exact
# classifier-authoritative shape - the [key=<slug>] token BETWEEN the verb and
# the colon - for both needs-decision and blocked.
test_ship_and_scout_teach_correct_key_placement() {
  local home brief
  home="$TMP_ROOT/key-placement-home"
  mkdir -p "$home/data"
  write_registry "$home"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-key-ship some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "fm-brief.sh ship scaffold exited non-zero"
  brief="$home/data/brief-key-ship/brief.md"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'needs-decision [key=<slug>]: {summary}' "$brief" \
    "ship brief did not show the correct needs-decision key placement"
  # shellcheck disable=SC2016
  assert_grep 'blocked [key=<slug>]: {why}' "$brief" \
    "ship brief did not show the correct blocked key placement"
  assert_grep "folds under the default key" "$brief" \
    "ship brief did not warn that a key buried in the note folds under default"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-key-scout some-proj --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$home/data/brief-key-scout/brief.md"
  # shellcheck disable=SC2016
  assert_grep 'needs-decision [key=<slug>]: {summary}' "$brief" \
    "scout brief did not show the correct needs-decision key placement"
  # shellcheck disable=SC2016
  assert_grep 'blocked [key=<slug>]: {why}' "$brief" \
    "scout brief did not show the correct blocked key placement"
  assert_grep "folds under the default key" "$brief" \
    "scout brief did not warn that a key buried in the note folds under default"
  pass "fm-brief.sh: ship and scout scaffolds teach the classifier's authoritative key placement"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"
  assert_grep "you may host the Lavish review loop yourself" "$brief" \
    "scout brief must mention the option to host a Lavish review loop"
  assert_grep "## Captain's intent" "$brief" "scout brief missing Captain's intent subsection"
  assert_grep "## Firstmate spec" "$brief" "scout brief missing Firstmate spec subsection"
  assert_grep "{FIRSTMATE_SPEC}" "$brief" "scout brief missing the spec placeholder"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  assert_no_grep "## Captain's intent" "$brief" \
    "secondmate charter must not grow ship/scout Task subsections"
  assert_no_grep "{FIRSTMATE_SPEC}" "$brief" \
    "secondmate charter must not carry the Firstmate spec placeholder"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

# A prior opencode task's write tool silently rebased an absolute host path
# onto its own worktree root, so a status-file append and a scout report both
# landed inside the disposable worktree instead of surviving teardown. Every
# scaffold must instruct the worker to verify the real absolute path with
# `ls -la` before trusting a status append or a report write, so a silent
# misplace becomes a loud `blocked:` instead of lost work.
test_status_and_report_writes_require_verification() {
  local home id brief status_file report_file
  home="$TMP_ROOT/write-verification-home"
  mkdir -p "$home/data"

  id="brief-verify-scout-r1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$home/data/$id/brief.md"
  status_file="$home/state/$id.status"
  report_file="$home/data/$id/report.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "After every append, verify with \`ls -la '$status_file'\`" "$brief" \
    "scout brief must require ls -la verification of the real status file after every append"
  assert_grep "a write tool can silently place the file somewhere else" "$brief" \
    "scout brief status-append rule must explain why verification is required"
  assert_grep "After writing it, verify with \`ls -la $report_file\`" "$brief" \
    "scout brief must require ls -la verification of the real report path after writing it"
  assert_grep "the write landed somewhere" "$brief" \
    "scout brief report verification must explain the failure is a blocked condition"

  id="brief-verify-ship-r1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" alpha --mode no-mistakes >/dev/null 2>&1 \
    || fail "fm-brief.sh ship scaffold exited non-zero"
  brief="$home/data/$id/brief.md"
  status_file="$home/state/$id.status"
  assert_present "$brief" "ship brief was not scaffolded"
  assert_grep "After every append, verify with \`ls -la '$status_file'\`" "$brief" \
    "ship brief must require ls -la verification of the real status file after every append"

  id="brief-verify-sm-r1"
  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$home/data/$id/brief.md"
  status_file="$home/state/$id.status"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "After writing that doc, verify with \`ls -la {path}\`" "$brief" \
    "secondmate charter must require ls -la verification of a written doc before pointing to it"
  assert_grep "After every append, verify with \`ls -la '$status_file'\`" "$brief" \
    "secondmate charter must require ls -la verification of the real status file after every append"
  assert_grep "a write tool can silently place the file somewhere else" "$brief" \
    "secondmate charter status-append rule must explain why verification is required"
  pass "fm-brief.sh: status appends and scout reports require ls -la verification before trust"
}

# Captain's 2026-08-18 post-mortem Q1: pt-tracker ship briefs carry the
# tracker-entry law as a literal, explicit requirement block. Non-pt-tracker
# briefs, scouts, and secondmate charters are unaffected.
test_pt_tracker_brief_carries_tracker_entry_law() {
  local home id brief
  home="$TMP_ROOT/pt-tracker-law-home"
  mkdir -p "$home/data"

  # pt-tracker ship brief must contain the law with both preconditions.
  id="brief-pt-tracker-law-t1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" pt-tracker --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "pt-tracker brief was not scaffolded"
  assert_grep "# pt-tracker tracker-entry law" "$brief" \
    "pt-tracker brief missing the tracker-entry law heading"
  assert_grep "ROADMAP execution prompt" "$brief" \
    "pt-tracker brief missing the ROADMAP execution prompt requirement"
  assert_grep "CURRENT.md tracker entry" "$brief" \
    "pt-tracker brief missing the CURRENT.md tracker entry requirement"
  assert_grep "pre-dispatch precondition" "$brief" \
    "pt-tracker brief must state the precondition is pre-dispatch, not post-dispatch"

  # Alternate spellings of the same repo still trigger the law: REPO is a free
  # string, and a dispatcher naming owner/repo, a path, or a .git suffix must not
  # silently lose the precondition.
  local spelling
  for spelling in sKeLe100/pt-tracker pt-tracker.git "$TMP_ROOT/repos/pt-tracker"; do
    id="brief-pt-tracker-law-$(printf '%s' "$spelling" | tr -c '[:alnum:]' -)"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$spelling" --mode no-mistakes >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "brief for repo spelling '$spelling' was not scaffolded"
    assert_grep "# pt-tracker tracker-entry law" "$brief" \
      "repo spelling '$spelling' must still carry the tracker-entry law"
  done

  # A different project must NOT carry the law.
  id="brief-other-proj-t1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-repo --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "other repo brief was not scaffolded"
  assert_no_grep "tracker-entry law" "$brief" \
    "non-pt-tracker brief must not carry the tracker-entry law"
  if grep -B2 '^# Project memory$' "$brief" | head -2 | grep -q '[^[:space:]]'; then
    :
  else
    fail "non-pt-tracker brief gained a blank line before the project-memory section"
  fi

  # A scout brief for pt-tracker must NOT carry the law (scouts don't ship).
  id="brief-pt-scout-t1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" pt-tracker --scout >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "pt-tracker scout was not scaffolded"
  assert_no_grep "tracker-entry law" "$brief" \
    "pt-tracker scout brief must not carry the tracker-entry law"

  pass "fm-brief.sh: pt-tracker ship brief carries the tracker-entry law; other briefs are unaffected"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_ship_mode_is_required_and_closed_set
test_ship_mode_is_explicit_not_registry
test_delivery_flags_are_refused_where_they_do_not_apply
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_perspective_flag_inserts_catalog_fragment_and_marker
test_perspective_flag_refuses_unknown_or_unsafe_slug
test_perspective_strip_keeps_prose_around_comments
test_perspective_catalog_fragments_stay_within_bounds
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_documented_global_replace_leaves_the_herdr_gate_intact
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_ship_and_scout_teach_correct_key_placement
test_scout_and_secondmate_scaffold
test_status_and_report_writes_require_verification
test_pt_tracker_brief_carries_tracker_entry_law

# The generated brief is fm-brief.sh's public output artifact - the prompt a
# claude-harness worker is actually launched with - so its Rules block is an
# owned text contract. This checks two behaviors of that emitted contract:
# the context-policy rule names a helper path that really resolves and runs,
# and the Rules list is numbered contiguously so cross-references elsewhere
# (bin/fm-classify-lib.sh cites "rule 7") point at the rule they claim.
test_ship_brief_context_rule_and_rule_numbering() {
  local home id brief helper nums expected n
  home="$TMP_ROOT/context-rule-home"
  mkdir -p "$home/data"
  id="brief-context-r1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"

  assert_grep "padded-countdown token counter" "$brief" \
    "ship brief lost the unreliable-token-counter rule"
  assert_grep "/context" "$brief" "ship brief lost the /context fallback instruction"

  # The helper the rule points workers at must be a real absolute executable.
  helper=$(sed -n 's#.*use /context or \(/[^ ]*fm-context-usage\.sh\).*#\1#p' "$brief" | head -1)
  [ -n "$helper" ] || fail "context rule does not name an absolute fm-context-usage.sh path"
  [ -x "$helper" ] || fail "context rule points at a non-executable helper: $helper"
  "$helper" --help >/dev/null 2>&1 || fail "helper named by the context rule does not run: $helper"

  # Rules are numbered 1..N with no gaps or repeats.
  nums=$(sed -n '/^# Rules$/,/^# /p' "$brief" | sed -n 's/^ *\([0-9][0-9]*\)\. .*/\1/p')
  [ -n "$nums" ] || fail "no numbered rules found in the generated brief"
  n=0
  expected=1
  for n in $nums; do
    [ "$n" = "$expected" ] || fail "brief rule numbering is not contiguous: expected $expected, got $n"
    expected=$((expected + 1))
  done
  [ "$n" -ge 8 ] || fail "brief lost rules; last rule number is $n"
  pass "fm-brief.sh: ship brief names a runnable context helper and numbers rules contiguously"
}
test_ship_brief_context_rule_and_rule_numbering

test_ship_brief_carries_retry_loop_failsafe() {
  local home id brief
  home="$TMP_ROOT/retry-loop-home"
  mkdir -p "$home/data"
  id="brief-retry-loop-r1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"

  assert_grep "Retry-loop failsafe" "$brief" \
    "ship brief lost the retry-loop failsafe rule"
  assert_grep "2 consecutive fix no-ops" "$brief" \
    "retry-loop rule lost its fix no-op ceiling"
  assert_grep "after 4 review" "$brief" \
    "retry-loop rule lost its review-round ceiling"
  assert_grep "blocked [key=retry-loop]:" "$brief" \
    "retry-loop rule lost its keyed reporting contract"
  pass "fm-brief.sh: ship brief carries the retry-loop failsafe rule with its ceilings and key"
}
test_ship_brief_carries_retry_loop_failsafe

test_upstream_sync_brief_carries_the_hard_gates() {
  local home id brief out
  home="$TMP_ROOT/upstream-sync-home"
  mkdir -p "$home/data"
  id="brief-upstream-sync-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes --upstream-sync >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "upstream-sync brief was not scaffolded"
  assert_grep "# Upstream sync - HARD SAFETY GATES" "$brief" \
    "upstream-sync brief missing its hard safety gates section"
  assert_grep "NEVER YOLO-MERGE" "$brief" \
    "upstream-sync brief must state the never-yolo-merge instruction"
  assert_grep "SUPERVISION-SAFETY CONFLICT STOP" "$brief" \
    "upstream-sync brief must state the supervision-safety-file-conflict stop"
  assert_grep "bin/fm-watch.sh, bin/fm-classify-lib.sh, bin/fm-wake-lib.sh, bin/fm-wake-drain.sh, bin/fm-task-inbox-lib.sh, or bin/fm-teardown.sh" "$brief" \
    "upstream-sync brief must name the full supervision-safety file list"
  local sf
  for sf in fm-watch.sh fm-classify-lib.sh fm-wake-lib.sh fm-wake-drain.sh fm-task-inbox-lib.sh fm-teardown.sh; do
    [ -f "$ROOT/bin/$sf" ] || fail "the gate names bin/$sf, which does not exist in this repo"
    assert_grep "bin/$sf" "$brief" "upstream-sync brief must name bin/$sf in its conflict stop"
  done
  assert_grep "NON-PRE-EXISTING REGRESSION STOP" "$brief" \
    "upstream-sync brief must state the non-pre-existing-regression stop"
  assert_grep "PR PURITY" "$brief" \
    "upstream-sync brief must state the PR-purity requirement"

  local scout_id
  scout_id="brief-upstream-sync-scout-d1"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$scout_id" firstmate --scout --upstream-sync 2>&1)
  echo "$out" | grep -q "error: --upstream-sync applies only to a ship brief" \
    || fail "--upstream-sync must be refused on a non-ship brief, got: $out"

  pass "fm-brief.sh: --upstream-sync emits the never-yolo-merge, supervision-safety, regression, and PR-purity gates"
}
test_upstream_sync_brief_carries_the_hard_gates

test_ship_brief_round_ceiling_follows_configured_thresholds() {
  local home id brief
  home="$TMP_ROOT/retry-rounds-home"
  mkdir -p "$home/data" "$home/config"
  printf 'rounds=6\n' > "$home/config/retry-thresholds"
  id="brief-retry-rounds-r1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "after 6 review" "$brief" \
    "retry-loop rule must use the configured rounds ceiling"
  assert_grep "2 consecutive fix no-ops" "$brief" \
    "configured rounds must not disturb the fixed no-op ceiling"

  local cfg_dir id2 brief2
  cfg_dir="$TMP_ROOT/retry-rounds-cfg"
  mkdir -p "$cfg_dir"
  printf 'rounds=9\n' > "$cfg_dir/retry-thresholds"
  id2="brief-retry-rounds-r2"
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$cfg_dir" "$ROOT/bin/fm-brief.sh" "$id2" some-proj --mode no-mistakes >/dev/null 2>&1
  brief2="$home/data/$id2/brief.md"
  assert_present "$brief2" "override brief was not scaffolded"
  assert_grep "after 9 review" "$brief2" \
    "retry-loop rule must honor FM_CONFIG_OVERRIDE for the rounds ceiling"

  local id3 brief3
  printf 'rounds=abc\n' > "$cfg_dir/retry-thresholds"
  id3="brief-retry-rounds-r3"
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$cfg_dir" "$ROOT/bin/fm-brief.sh" "$id3" some-proj --mode no-mistakes >/dev/null 2>&1
  brief3="$home/data/$id3/brief.md"
  assert_present "$brief3" "malformed-threshold brief was not scaffolded"
  assert_grep "after 4 review" "$brief3" \
    "a malformed rounds= value must fall back to the default ceiling"
  pass "fm-brief.sh: retry-loop review-round ceiling follows config/retry-thresholds"
}
test_ship_brief_round_ceiling_follows_configured_thresholds
