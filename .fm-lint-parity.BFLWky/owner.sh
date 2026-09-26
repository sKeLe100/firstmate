#!/usr/bin/env bash
# shellcheck source=.fm-lint-parity.BFLWky/owner-dep.sh
. "/home/sean_/.no-mistakes/worktrees/4936102b4bcf/01M3DW5CDTCHY6TS6YCJF85WAT/.fm-lint-parity.BFLWky/owner-dep.sh"
owner_bad() {
  printf '%s\n' "$owner_dependency_value"
  cd "$1"
}
