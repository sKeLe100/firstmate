#!/usr/bin/env bash
# Regression tests for the config/dispatch-cap quota ladder documentation
# (captain ruling 2026-09-02): the tightened percent-remaining floor and the
# new elapsed-time-in-window dimension must land in docs/configuration.md
# (the source of truth) AND stay consistent with the restatement in
# .agents/skills/autonomous/SKILL.md step 3, since that is the only other
# place the ladder is consulted/restated (no script computes the effective
# cap; it is applied by the dispatching agent reading both files).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIG_DOC="$ROOT/docs/configuration.md"
AUTONOMOUS_SKILL="$ROOT/.agents/skills/autonomous/SKILL.md"

test_config_doc_has_tightened_floor_and_no_stale_threshold() {
  local doc
  doc=$(cat "$CONFIG_DOC")
  assert_contains "$doc" 'five_hour.percentRemaining <= 15' \
    "docs/configuration.md must state the tightened cap-1 floor"
  assert_not_contains "$doc" 'five_hour.percentRemaining < 10' \
    "docs/configuration.md must not retain the superseded 10% floor"
  pass "docs/configuration.md states the tightened percentRemaining <= 15 floor"
}

test_config_doc_has_elapsed_time_dimension() {
  local doc
  doc=$(cat "$CONFIG_DOC")
  assert_contains "$doc" '2.5-hour mark' \
    "docs/configuration.md must document the 2.5-hour elapsed-time split"
  assert_contains "$doc" 'resetsAt' \
    "docs/configuration.md must explain how elapsed time is derived from resetsAt"
  pass "docs/configuration.md documents the elapsed-time-in-window dimension"
}

test_autonomous_skill_restatement_matches_tightened_floor() {
  local skill
  skill=$(cat "$AUTONOMOUS_SKILL")
  assert_contains "$skill" 'five_hour.percentRemaining <= 15' \
    "autonomous SKILL.md step 3 must restate the tightened cap-1 floor, not the old one"
  assert_not_contains "$skill" 'five_hour.percentRemaining < 10' \
    "autonomous SKILL.md step 3 must not retain the superseded 10% floor"
  pass "autonomous SKILL.md's restated floor matches docs/configuration.md"
}

test_autonomous_skill_mentions_elapsed_time_dimension() {
  local skill
  skill=$(cat "$AUTONOMOUS_SKILL")
  assert_contains "$skill" '2.5-hour' \
    "autonomous SKILL.md step 3 must mention the new elapsed-time dimension so dispatch isn't computed from a stale summary"
  pass "autonomous SKILL.md's restatement covers the elapsed-time dimension"
}

test_config_doc_has_tightened_floor_and_no_stale_threshold
test_config_doc_has_elapsed_time_dimension
test_autonomous_skill_restatement_matches_tightened_floor
test_autonomous_skill_mentions_elapsed_time_dimension
