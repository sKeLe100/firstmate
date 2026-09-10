#!/usr/bin/env bash
# fm-agentsmd-size.sh - Assert AGENTS.md stays under a resident-size ceiling.
# Usage: bin/fm-agentsmd-size.sh
# Exit 0 if within budget, exit 1 with a diagnostic if over.
set -euo pipefail

usage() {
  echo "Usage: bin/fm-agentsmd-size.sh"
  echo "Assert AGENTS.md stays under a resident-size ceiling."
  echo "Exit 0 if within budget, exit 1 with a diagnostic if over."
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *)
    echo "fm-agentsmd-size: unexpected argument '$1'; this check takes no arguments" >&2
    usage >&2
    exit 2
    ;;
esac

CEILING=102400  # 100KB resident-size ceiling for AGENTS.md
AGENTS_FILE="$(git rev-parse --show-toplevel)/AGENTS.md"

if [[ ! -f "$AGENTS_FILE" ]]; then
  echo "fm-agentsmd-size: AGENTS.md not found at $AGENTS_FILE" >&2
  exit 1
fi

SIZE=$(wc -c < "$AGENTS_FILE")
if (( SIZE > CEILING )); then
  echo "AGENTS.md is ${SIZE} bytes, exceeds ${CEILING} byte ceiling (100KB). Trim resident lookup tables and duplicated detail; docs/configuration.md owns configuration schema detail." >&2
  exit 1
fi
echo "AGENTS.md: ${SIZE} bytes (ceiling: ${CEILING})"
