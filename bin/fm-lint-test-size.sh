#!/usr/bin/env bash
# fm-lint-test-size.sh - refuse an oversized tests/*.test.sh file that isn't
# grandfathered.
#
# A single test script growing past a few thousand lines or a few hundred
# test_ cases becomes its own retry-unit problem: one unrelated failure forces
# re-running the whole file, and CI shard balance and review size degrade with
# it (the incident that produced fm-teardown-test-split, at 160 cases). This
# guard fails on any tests/*.test.sh over the line or test_-function ceiling
# that is not named in the shrinking allowlist at
# tests/fm-lint-test-size-allowlist.txt, and fails on a stale allowlist entry
# (a file that no longer exists, or no longer exceeds either ceiling) so the
# list is forced to shrink as splits land instead of rotting. bin/fm-lint.sh
# invokes this owner on its default (no explicit-path) path, matching
# bin/fm-lint-workflows.sh's pattern; no new CI job.
#
# Usage:
#   fm-lint-test-size.sh                check tests/*.test.sh under this repo
#   fm-lint-test-size.sh --root <dir>   check tests/*.test.sh under <dir>
#   fm-lint-test-size.sh --help
set -eu

LINE_CEILING=3000
FUNC_CEILING=100

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint-test-size.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

fm_lint_test_size_usage() {
  sed -n '2,17{s/^# \{0,1\}//;p;}' "$SELF"
}

EXPLICIT_ROOT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || {
        printf 'fm-lint-test-size.sh: --root requires a directory.\n' >&2
        exit 2
      }
      EXPLICIT_ROOT=$2
      shift 2
      ;;
    --root=*)
      EXPLICIT_ROOT=${1#*=}
      shift
      ;;
    --help|-h)
      fm_lint_test_size_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'fm-lint-test-size.sh: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      printf 'fm-lint-test-size.sh: unexpected argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ -n "$EXPLICIT_ROOT" ]; then
  [ -d "$EXPLICIT_ROOT" ] || {
    printf 'fm-lint-test-size.sh: --root is not a directory: %s\n' "$EXPLICIT_ROOT" >&2
    exit 2
  }
  ROOT="$(cd "$EXPLICIT_ROOT" && pwd)"
fi

TESTS_DIR="$ROOT/tests"
ALLOWLIST="$TESTS_DIR/fm-lint-test-size-allowlist.txt"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint-test-size.XXXXXX") || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT
ALLOWLIST_CLEAN="$TMP_DIR/allowlist"
SEEN="$TMP_DIR/seen"
: > "$ALLOWLIST_CLEAN"
: > "$SEEN"

if [ -f "$ALLOWLIST" ]; then
  while IFS= read -r entry || [ -n "$entry" ]; do
    entry=${entry%%#*}
    # Portable trim (no associative arrays: this must run on stock macOS
    # Bash 3.2 as well as 4+, matching bin/fm-classify-lib.sh's convention).
    entry=$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$entry" ] || continue
    printf '%s\n' "$entry" >> "$ALLOWLIST_CLEAN"
  done < "$ALLOWLIST"
fi

rc=0
if [ -d "$TESTS_DIR" ]; then
  for path in "$TESTS_DIR"/*.test.sh; do
    [ -f "$path" ] || continue
    base=${path##*/}
    printf '%s\n' "$base" >> "$SEEN"
    lines=$(wc -l < "$path" | tr -d '[:space:]')
    funcs=$(grep -c '^test_[A-Za-z0-9_]*()' "$path" || true)
    case "$funcs" in ''|*[!0-9]*) funcs=0 ;; esac
    over=0
    if [ "$lines" -gt "$LINE_CEILING" ] || [ "$funcs" -gt "$FUNC_CEILING" ]; then
      over=1
    fi
    if [ "$over" -eq 1 ] && ! grep -qxF "$base" "$ALLOWLIST_CLEAN"; then
      printf 'fm-lint-test-size.sh: %s exceeds the size ceiling (lines=%s ceiling=%s test_functions=%s ceiling=%s) and is not grandfathered in %s.\n' \
        "$path" "$lines" "$LINE_CEILING" "$funcs" "$FUNC_CEILING" "$ALLOWLIST" >&2
      rc=1
    fi
  done
fi

# A shrinking allowlist: an entry naming a file that no longer exists, or one
# that no longer exceeds either ceiling, must be removed as its split lands.
while IFS= read -r base || [ -n "$base" ]; do
  [ -n "$base" ] || continue
  if ! grep -qxF "$base" "$SEEN"; then
    printf 'fm-lint-test-size.sh: %s in %s no longer exists; remove its allowlist entry.\n' \
      "$base" "$ALLOWLIST" >&2
    rc=1
    continue
  fi
  path="$TESTS_DIR/$base"
  lines=$(wc -l < "$path" | tr -d '[:space:]')
  funcs=$(grep -c '^test_[A-Za-z0-9_]*()' "$path" || true)
  case "$funcs" in ''|*[!0-9]*) funcs=0 ;; esac
  if [ "$lines" -le "$LINE_CEILING" ] && [ "$funcs" -le "$FUNC_CEILING" ]; then
    printf 'fm-lint-test-size.sh: %s in %s no longer exceeds the ceiling (lines=%s test_functions=%s); remove its allowlist entry.\n' \
      "$base" "$ALLOWLIST" "$lines" "$funcs" >&2
    rc=1
  fi
done < "$ALLOWLIST_CLEAN"

if [ "$rc" -eq 0 ]; then
  allow_count=$(wc -l < "$ALLOWLIST_CLEAN" | tr -d '[:space:]')
  printf 'fm-lint-test-size.sh: tests/*.test.sh sizes ok (%s allowlisted)\n' "$allow_count"
fi
exit "$rc"
