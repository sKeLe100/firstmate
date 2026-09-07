#!/usr/bin/env bash
# Post-green verification gate: grep-verify that a claim text's asserted
# file paths were actually touched in this branch's diff, catching a "done"
# summary that names files never committed.
# Usage: fm-claim-check.sh <base-ref>
# Reads the claim text from stdin.
# A path-shaped token (containing a "/" and a file extension) counts as a
# claim only when a change verb (created/added/modified/updated/wired/...)
# governs it: the verb appears within a few preceding words, with no clause
# break and no reference word ("matches", "per", "see", ...) in between. A
# path merely cited for comparison or reference is not a claim.
# Exit 0: every asserted path was touched (or none was asserted).
# Exit 1: at least one asserted path was not touched in the diff.
# Exit 2: usage or git error.
set -u

usage() {
  cat <<'EOF'
Usage: fm-claim-check.sh <base-ref>

Grep-verifies a claim text's asserted file paths against the diff of HEAD
against <base-ref>. Reads the claim text from stdin. Only a path governed
by a change verb is treated as a claim; a path merely cited (e.g.
"updated bin/x.sh to match docs/architecture.md") is ignored.

Exit 0: every asserted path was touched in the diff.
Exit 1: at least one asserted path was not touched; unverified paths are
        printed one per line on stdout.
Exit 2: usage error or the diff could not be computed.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi

BASE_REF=$1
CLAIM_TEXT=$(cat)

DIFF_FILES=$(git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null) \
  || { echo "error: cannot diff HEAD against '$BASE_REF'" >&2; exit 2; }

CLAIMED_PATHS=$(printf '%s\n' "$CLAIM_TEXT" | awk '
BEGIN {
  verb = "^(add(s|ed|ing)?|creat(e|es|ed|ing)|introduc(e|es|ed|ing)|implement(s|ed|ing)?|writ(e|es|ing)|wrote|modif(y|ies|ied|ying)|updat(e|es|ed|ing)|chang(e|es|ed|ing)|edit(s|ed|ing)?|patch(es|ed|ing)?|fix(es|ed|ing)?|refactor(s|ed|ing)?|remov(e|es|ed|ing)|delet(e|es|ed|ing)|drop(s|ped|ping)?|wir(e|es|ed|ing)|extend(s|ed|ing)?|touch(es|ed|ing)?|replac(e|es|ed|ing)|reworked|rewrote|rewritten|hardened|ported)$";
  ref = "^(match(es|ed|ing)?|mirror(s|ed|ing)?|per|see|described|documented|according|consistent|like|same|compar(e|es|ed|ing)|referenc(e|es|ed|ing)|cit(e|es|ed|ing)|follow(s|ed|ing)?|against|unchanged|existing|unlike|versus|vs)$";
  path = "[A-Za-z0-9_./-]+/[A-Za-z0-9_./-]+\\.[A-Za-z0-9]+";
  since = 99;
}
{
  for (i = 1; i <= NF; i++) {
    w = $i;
    bare = tolower(w);
    gsub(/^[^A-Za-z0-9_.\/-]+|[^A-Za-z0-9_.\/-]+$/, "", bare);
    if (since <= 5 && match(w, path)) print substr(w, RSTART, RLENGTH);
    if (bare ~ ref || w ~ /[;,.]$/) since = 99;
    else if (bare ~ verb) since = 0;
    else since++;
  }
  since = 99;
}
' | sort -u)

if [ -z "$CLAIMED_PATHS" ]; then
  exit 0
fi

UNVERIFIED=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if ! printf '%s\n' "$DIFF_FILES" | grep -qxF "$path"; then
    UNVERIFIED="$UNVERIFIED$path
"
  fi
done <<<"$CLAIMED_PATHS"

if [ -n "$UNVERIFIED" ]; then
  printf '%s' "$UNVERIFIED"
  exit 1
fi

exit 0
