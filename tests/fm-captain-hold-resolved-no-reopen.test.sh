#!/usr/bin/env bash
# tests/fm-captain-hold-resolved-no-reopen.test.sh - a relayed captain hold the
# parent already closed (the captain's answer or deferral, written by
# fm-send --resolve-key) must not come back as a fresh needs-decision when the
# secondmate restates the same hold. Drives the real parent-channel writer for
# a local mate, then the real drain, asserting OPEN DECISIONS stays empty for
# the closed key while a new occurrence of the hold still opens.
# The remote mirror twin lives in tests/fm-remote-reply.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold-resolved-no-reopen)

# shellcheck source=bin/fm-parent-channel-lib.sh
. "$ROOT/bin/fm-parent-channel-lib.sh"

# A local mate home bound to the case's own state dir as its parent.
make_mate() {  # <case-dir>
  local dir=$1 mate
  mate="$dir/mate"
  mkdir -p "$mate/state"
  printf 'pc02-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$dir" \
    > "$mate/.fm-secondmate-parent"
  printf '%s\n' "$mate"
}

publish() {  # <mate> <line>
  fm_parent_channel_report "$1" "$1/state" "$2" || fail "parent channel refused: $2"
}

test_resolved_hold_stays_closed() {
  local dir mate out status
  dir=$(make_case closed)
  mate=$(make_mate "$dir")
  status="$dir/state/pc02-mate.status"

  publish "$mate" 'needs-decision [key=captain-hold-gallery-1]: captain hold gallery: needs rescope'
  # What fm-send --resolve-key appends at answer time.
  printf 'resolved [key=captain-hold-gallery-1]: answered: keep held, revisit on CI pressure\n' >> "$status"
  # The mate restates the hold with the captain's answer folded into the reason.
  publish "$mate" 'needs-decision [key=captain-hold-gallery-1]: captain hold gallery: keep held, revisit later'

  [ "$(grep -c 'needs-decision' "$status")" = 1 ] \
    || fail "the restated captain hold was appended after the parent closed its key"
  out="$dir/drain.out"
  FM_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$out" || fail "drain failed"
  grep -F 'captain-hold-gallery-1' "$out" >/dev/null \
    && fail "a resolved captain hold is listed in OPEN DECISIONS again"
  pass "a restated captain hold stays closed after the parent resolved its key"
}

test_new_occurrence_still_opens() {
  local dir mate out
  dir=$(make_case occurrence)
  mate=$(make_mate "$dir")

  publish "$mate" 'needs-decision [key=captain-hold-gallery-1]: captain hold gallery: needs rescope'
  printf 'resolved [key=captain-hold-gallery-1]: answered: rescoped\n' >> "$dir/state/pc02-mate.status"
  publish "$mate" 'needs-decision [key=captain-hold-gallery-2]: captain hold gallery: a new question'

  out="$dir/drain.out"
  FM_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$out" || fail "drain failed"
  grep -F 'captain-hold-gallery-2' "$out" >/dev/null \
    || fail "a new occurrence of the captain hold did not open"
  grep -F 'captain-hold-gallery-1' "$out" >/dev/null \
    && fail "the closed occurrence listed alongside the new one"
  pass "a new occurrence of a captain hold still opens"
}

test_unresolved_restatement_and_other_keys_unchanged() {
  local dir mate status
  dir=$(make_case unresolved)
  mate=$(make_mate "$dir")
  status="$dir/state/pc02-mate.status"

  publish "$mate" 'needs-decision [key=captain-hold-gallery-1]: captain hold gallery: needs rescope'
  publish "$mate" 'needs-decision [key=captain-hold-gallery-1]: captain hold gallery: reworded while still open'
  [ "$(grep -c 'captain-hold-gallery-1' "$status")" = 2 ] \
    || fail "a restated hold the parent never closed no longer republishes"
  # An ordinary key is never subject to the rule, even after its own close.
  printf 'resolved [key=api-shape]: done\n' >> "$status"
  publish "$mate" 'needs-decision [key=api-shape]: reopened by its owner'
  grep -F 'reopened by its owner' "$status" >/dev/null \
    || fail "an ordinary decision key stopped reopening"
  pass "unresolved restatements and ordinary keys behave as before"
}

test_resolved_hold_stays_closed
test_new_occurrence_still_opens
test_unresolved_restatement_and_other_keys_unchanged
