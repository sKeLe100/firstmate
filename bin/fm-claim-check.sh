#!/usr/bin/env bash
# Post-green verification gate: check that the file paths named in a claim
# text exist as git facts, catching a "done" summary that names files the
# branch never produced.
# Usage: fm-claim-check.sh <base-ref>
# Reads the claim text from stdin.
# Every path-shaped token (containing a "/" and a file extension) is checked
# against git in one of two tiers:
#   - a path claimed as changed - it follows an unambiguous change verb
#     (created/added/modified/updated/wrote, ...) within a few words, and so
#     does every further path the verb lists after it via "and" or a comma -
#     must appear in `git diff --name-only <base-ref>...HEAD`.
#   - any other mentioned path is a citation and only has to be tracked at
#     HEAD, so a summary may freely reference unchanged files.
# The verb list is deliberately short. A phrasing it does not recognize falls
# through to the permissive citation tier, so an unlisted synonym yields a
# missed claim rather than a false alarm on correct work. URLs are excluded
# before extraction, so a `done: PR https://... checks green` summary does not
# read as a path claim.
# Exit 0: every claimed path is a git fact (or the claim names no paths).
# Exit 1: at least one claimed path is not corroborated by git.
# Exit 2: usage or git error.
set -u

usage() {
  cat <<'EOF'
Usage: fm-claim-check.sh <base-ref>

Verifies the file paths named in a claim text against git facts. Reads the
claim text from stdin and classifies each path-shaped token in two tiers.

A path introduced by an unambiguous change verb (created, added, modified,
updated, wrote, ...), and every further path listed with it, must appear in
the diff of HEAD versus <base-ref>. Any
other mentioned path is treated as a citation and only has to be tracked at
HEAD. Unrecognized phrasing falls through to the citation tier, so the gate
errs toward accepting correct work. URLs are ignored.

Exit 0: every claimed path is a git fact, or the claim names no paths.
Exit 1: at least one claimed path is unverified; those paths are printed one
        per line on stdout.
Exit 2: usage error, or the diff could not be computed.
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

TRACKED_FILES=$(git ls-tree -r --name-only HEAD 2>/dev/null) \
  || { echo "error: cannot list files tracked at HEAD" >&2; exit 2; }

KNOWN_FILES=$(printf '%s\n%s\n' "$DIFF_FILES" "$TRACKED_FILES")

# A claimed path may be written "./bin/x.sh" or wrapped in backticks, quotes,
# or trailing punctuation; normalize those away before matching git's paths.
# Each emitted line is "<tier> <path>", tier being "changed" or "cited".
CLASSIFIED=$(printf '%s\n' "$CLAIM_TEXT" | awk '
  BEGIN {
    verbs = "^(create|creates|created|creating|add|adds|added|adding|" \
            "modify|modifies|modified|modifying|update|updates|updated|" \
            "updating|write|writes|wrote|writing|implement|implements|" \
            "implemented|implementing|delete|deletes|deleted|deleting|" \
            "remove|removes|removed|removing)$"
    window = 0
    inlist = 0
    conj = "^(and|&|plus|,)$"
  }
  {
    for (i = 1; i <= NF; i++) {
      tok = $i
      if (tok ~ /:\/\//) { continue }
      gsub(/^[`"\x27([<]+/, "", tok)
      gsub(/[`"\x27)\]>.,;:]+$/, "", tok)
      if (tok ~ /^[A-Za-z0-9_.\/-]+\/[A-Za-z0-9_.\/-]+\.[A-Za-z0-9]+$/) {
        sub(/^\.\//, "", tok)
        if (window > 0 || inlist) { print "changed " tok; window = 0; inlist = 1 }
        else { print "cited " tok; inlist = 0 }
        continue
      }
      if (tolower(tok) ~ verbs) { window = 4; inlist = 0; continue }
      if (inlist && tolower(tok) ~ conj) { continue }
      inlist = 0
      if (window > 0) { window-- }
    }
  }
' | sort -u)

if [ -z "$CLASSIFIED" ]; then
  exit 0
fi

UNVERIFIED=""
while IFS=' ' read -r tier path; do
  [ -n "$path" ] || continue
  if [ "$tier" = "changed" ]; then
    HAYSTACK=$DIFF_FILES
  else
    HAYSTACK=$KNOWN_FILES
  fi
  if ! printf '%s\n' "$HAYSTACK" | grep -qxF "$path"; then
    case "
$UNVERIFIED" in
      *"
$path
"*) ;;
      *) UNVERIFIED="$UNVERIFIED$path
" ;;
    esac
  fi
done <<EOF
$CLASSIFIED
EOF

if [ -n "$UNVERIFIED" ]; then
  printf '%s' "$UNVERIFIED"
  exit 1
fi

exit 0
