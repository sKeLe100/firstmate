#!/usr/bin/env bash
# fm-lint-nomistakes-config.sh - guard against a per-branch .no-mistakes.yaml
# test-command workaround becoming standing policy.
#
# PR #111 swapped commands.test from the canonical `bin/fm-test-run.sh
# --changed ...` selector for a fixed list of explicit tests/ paths "to fit
# the gate's time cap", with a comment scoping the swap to "this branch".
# That workaround landed as standing policy in the trusted default-branch
# copy: every no-mistakes run afterward tested only those scripts regardless
# of the actual diff, while GitHub's required check still certified full
# coverage (see fm-revert-nm111-test-regression). This guard fails loudly on
# either symptom recurring, in any explicit-path list or comment shape, not
# only the exact string that regressed: commands.test naming an explicit
# tests/ path (only bin/fm-test-run.sh's --changed selection is sanctioned),
# or any comment admitting the swap is scoped to "this branch". bin/fm-lint.sh
# invokes this owner on its default (no explicit-path) path, matching
# bin/fm-lint-workflows.sh's pattern; no new CI job.
#
# Usage:
#   fm-lint-nomistakes-config.sh              check .no-mistakes.yaml under this repo
#   fm-lint-nomistakes-config.sh --root <dir> check .no-mistakes.yaml under <dir>
#   fm-lint-nomistakes-config.sh <path>       check an explicit file
#   fm-lint-nomistakes-config.sh --help
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint-nomistakes-config.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

fm_lint_nomistakes_config_usage() {
  sed -n '2,18{s/^# \{0,1\}//;p;}' "$SELF"
}

EXPLICIT_ROOT=
EXPLICIT_PATH=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || {
        printf 'fm-lint-nomistakes-config.sh: --root requires a directory.\n' >&2
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
      fm_lint_nomistakes_config_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'fm-lint-nomistakes-config.sh: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [ "$#" -gt 0 ]; then
  [ "$#" -eq 1 ] || {
    printf 'fm-lint-nomistakes-config.sh: at most one explicit file.\n' >&2
    exit 2
  }
  EXPLICIT_PATH=$1
fi

if [ -n "$EXPLICIT_ROOT" ]; then
  [ -d "$EXPLICIT_ROOT" ] || {
    printf 'fm-lint-nomistakes-config.sh: --root is not a directory: %s\n' "$EXPLICIT_ROOT" >&2
    exit 2
  }
  ROOT="$(cd "$EXPLICIT_ROOT" && pwd)"
fi

if [ -n "$EXPLICIT_PATH" ]; then
  TARGET=$EXPLICIT_PATH
  [ -f "$TARGET" ] || {
    printf 'fm-lint-nomistakes-config.sh: file not found: %s\n' "$TARGET" >&2
    exit 2
  }
else
  TARGET="$ROOT/.no-mistakes.yaml"
  if [ ! -f "$TARGET" ]; then
    printf 'fm-lint-nomistakes-config.sh: no .no-mistakes.yaml under %s; nothing to check\n' "$ROOT"
    exit 0
  fi
fi

# Extract commands.test's value: the first `test:` key indented under the
# `commands:` mapping, stopping at the next column-0 key that ends it.
test_line=$(awk '
  /^commands:[[:space:]]*$/ { in_commands=1; next }
  in_commands && /^[^[:space:]#]/ { in_commands=0 }
  in_commands && /^[[:space:]]+test:[[:space:]]*/ {
    sub(/^[[:space:]]+test:[[:space:]]*/, "")
    print
    exit
  }
' "$TARGET")
test_line=${test_line%%#*}
test_line=${test_line#\'}
test_line=${test_line%\'}

rc=0

case "$test_line" in
  *tests/*)
    printf 'fm-lint-nomistakes-config.sh: %s commands.test names an explicit tests/ path: %s\n' \
      "$TARGET" "$test_line" >&2
    printf 'fm-lint-nomistakes-config.sh: use bin/fm-test-run.sh --changed selection instead of a fixed script list.\n' >&2
    rc=1
    ;;
esac

flagged=$(grep -n '^[[:space:]]*#' "$TARGET" | grep -i 'this branch' | head -1 || true)
if [ -n "$flagged" ]; then
  printf 'fm-lint-nomistakes-config.sh: a comment in %s scopes itself to "this branch":\n' "$TARGET" >&2
  printf 'fm-lint-nomistakes-config.sh: %s\n' "$flagged" >&2
  printf 'fm-lint-nomistakes-config.sh: a per-branch workaround must not land as standing policy in the trusted default-branch copy.\n' >&2
  rc=1
fi

[ "$rc" -ne 0 ] || printf 'fm-lint-nomistakes-config.sh: %s ok\n' "$TARGET"
exit "$rc"
