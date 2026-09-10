#!/usr/bin/env bash
# tests/fm-agentsmd-size.test.sh - regression test for AGENTS.md resident-size
# ceiling check (bin/fm-agentsmd-size.sh). Verifies the script passes when the
# file is within budget and fails with a clear diagnostic when it exceeds the
# 100KB ceiling.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/fm-agentsmd-size.sh"
AGENTS="$ROOT/AGENTS.md"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }
pad_line() {
  printf '# Padding line for the AGENTS.md resident-size ceiling regression test %019d\n' "$1"
}

# shellcheck disable=SC2154
: "${TMPDIR:=/tmp}"

# ---------------------------------------------------------------------------
# T1: script passes when AGENTS.md is under the ceiling
# ---------------------------------------------------------------------------
test_under_ceiling() {
  local out status size
  size=$(wc -c < "$AGENTS")
  out=$("$SCRIPT" 2>&1) && status=0 || status=$?
  if [ "$status" -eq 0 ] && echo "$out" | grep -q "bytes"; then
    pass "passes when AGENTS.md ($size bytes) is under the 100KB ceiling"
  else
    fail "should pass when under ceiling: status=$status output='$out'"
  fi
}

# ---------------------------------------------------------------------------
# T2: script fails with a diagnostic when over the ceiling
# ---------------------------------------------------------------------------
test_over_ceiling() {
  local saved out status
  saved=$(mktemp "${TMPDIR}/fm-size-saved.XXXXXX")
  cp "$AGENTS" "$saved"

  # Create a file over 100KB by padding with comment-like lines
  local big ceiling cur pad_width pad_lines
  ceiling=$(sed -n 's/^CEILING=\([0-9]*\).*/\1/p' "$SCRIPT")
  big=$(mktemp "${TMPDIR}/fm-size-big.XXXXXX")
  cp "$saved" "$big"
  cur=$(wc -c < "$big")
  # Pad past the ceiling regardless of the current file size, deriving the
  # per-line width from the same printf that emits the padding.
  pad_width=$(pad_line 1 | wc -c)
  pad_lines=$(( (ceiling - cur) / pad_width + 64 ))
  if [ "$pad_lines" -lt 64 ]; then pad_lines=64; fi
  for ((i = 1; i <= pad_lines; i++)); do
    pad_line "$i"
  done >> "$big"
  local big_size
  big_size=$(wc -c < "$big")

  # Temporarily swap AGENTS.md
  cp "$big" "$AGENTS"
  out=$("$SCRIPT" 2>&1) && status=0 || status=$?
  if [ "$status" -ne 0 ] && echo "$out" | grep -q "bytes" && echo "$out" | grep -q "ceiling"; then
    pass "fails ($status) with diagnostic when AGENTS.md ($big_size bytes) exceeds 100KB"
  else
    fail "should fail when over ceiling: status=$status output='$out'"
  fi

  # Restore original
  cp "$saved" "$AGENTS"
  rm -f "$saved" "$big"
}

# ---------------------------------------------------------------------------
# T3: script errors when AGENTS.md is missing
# ---------------------------------------------------------------------------
test_missing_file() {
  local saved out status
  saved=$(mktemp "${TMPDIR}/fm-size-saved2.XXXXXX")
  cp "$AGENTS" "$saved"
  rm -f "$AGENTS"

  out=$("$SCRIPT" 2>&1) && status=0 || status=$?
  if [ "$status" -ne 0 ]; then
    pass "fails when AGENTS.md is missing"
  else
    fail "should fail when AGENTS.md is missing"
  fi

  cp "$saved" "$AGENTS"
  rm -f "$saved"
}

# ---------------------------------------------------------------------------
# T4: output format includes both actual size and ceiling
# ---------------------------------------------------------------------------
test_output_format() {
  local out
  out=$("$SCRIPT" 2>&1)
  local size
  size=$(wc -c < "$AGENTS")
  if echo "$out" | grep -q "$size" && echo "$out" | grep -q "102400"; then
    pass "output includes both actual size ($size) and ceiling (102400)"
  else
    fail "output format should include both size and ceiling: '$out'"
  fi
}

# Run all tests
test_under_ceiling
test_over_ceiling
test_missing_file
test_output_format

if [ "$FAILED" -ne 0 ]; then
  printf '\n%d test(s) failed\n' "$FAILED" >&2
  exit 1
fi
