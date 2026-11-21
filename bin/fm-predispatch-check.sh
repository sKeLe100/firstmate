#!/usr/bin/env bash
# fm-predispatch-check.sh - advisory "looks already landed" check before a ship
# task is dispatched.
#
# WHY THIS EXISTS. A task can be dispatched for work a merged pull request
# already landed, because the new task id and the old pull request's branch
# differ even though the ask is the same. The worker then rediscovers the landed
# change and reports back, which costs a whole lane. This script looks for that
# overlap cheaply and WARNS; it never refuses a dispatch, because a text match is
# evidence rather than proof and a false positive must not block real work.
#
# WHAT IT SEARCHES. Two local/forge sources for the project's GitHub origin:
#   - the most recent merged pull requests, matched on the task branch/id and on
#     significant shared title terms, and
#   - the most recent commits on origin's default branch, matched the same way.
# It reads only; it never fetches, writes, or changes repository state.
#
# DEGRADES QUIETLY. A missing gh, a non-GitHub origin, an unreachable forge, or
# no resolvable default branch all produce no output and exit 0. Only a match
# prints, so a normal dispatch stays quiet.
#
# Usage: fm-predispatch-check.sh <task-id> --project <dir> [--branch <branch>] [--text <text>]
#   --project  the project clone to search (its origin names the forge and its
#              remote-tracking refs supply the recent commits)
#   --branch   the ship branch, to match a merged pull request's head branch
#              (defaults to fm/<task-id>)
#   --text     the captain's ask or task title; its significant terms are the
#              fuzzy title signal. A short or empty text simply has fewer terms.
#
# Output lines go to stderr, prefixed "warning:", and the script always exits 0
# on a completed check, matches or not. A usage error exits 2.
set -u

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

ID=
PROJECT=
BRANCH=
TEXT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --project) PROJECT=${2:-}; shift 2 ;;
    --project=*) PROJECT=${1#--project=}; shift ;;
    --branch) BRANCH=${2:-}; shift 2 ;;
    --branch=*) BRANCH=${1#--branch=}; shift ;;
    --text) TEXT=${2:-}; shift 2 ;;
    --text=*) TEXT=${1#--text=}; shift ;;
    -*) echo "error: unknown option '$1'" >&2; exit 2 ;;
    *)
      if [ -z "$ID" ]; then ID=$1; else echo "error: unexpected argument '$1'" >&2; exit 2; fi
      shift ;;
  esac
done
[ -n "$ID" ] || { echo "error: task id is required" >&2; exit 2; }
[ -n "$PROJECT" ] || { echo "error: --project is required" >&2; exit 2; }
[ -d "$PROJECT" ] || { echo "error: --project is not a directory: $PROJECT" >&2; exit 2; }
[ -n "$BRANCH" ] || BRANCH="fm/$ID"

# Shared significant terms: lowercase alphanumeric tokens of four or more
# characters, minus a small stop list of words that carry no topical signal.
# The task id's own tokens are folded in so a task named after the feature
# matches a title that names the same feature in different words.
terms=$(
  {
    printf '%s\n' "$ID"
    printf '%s\n' "$TEXT"
  } | tr -cs '[:alnum:]' '\n' | tr '[:upper:]' '[:lower:]' |
    awk '
      BEGIN {
        n = split("a an and are as at be been before but by can check could did do does each every for from get had has have how in into is it its just like make merged more most no not of on one only or other our out same session should so some such than that the their them then there these they this those through to too two use used uses using was we were what when where which while who why will with would your you already landed change task gap priority add cheap warns warn look caught worker firstmate dispatch dispatched time day days date", s, " ")
        for (i = 1; i <= n; i++) stop[s[i]] = 1
      }
      {
        w = $0
        if (w !~ /^[a-z0-9]+$/) next
        if (length(w) < 4) next
        if (w in stop) next
        if (w in seen) next
        seen[w] = 1
        printf "%s ", w
      }'
)

# count_matches <terms> <text>: "<shared> <total>", the number of distinct shared
# stemmed tokens and the number of distinct significant tokens in the text.
# A trailing plural "s" is stripped on both sides so "disclosure" and
# "disclosures" count as the same term.
count_matches() {
  printf '%s' "$2" | awk -v terms="$1" '
    function stem(w) {
      w = tolower(w)
      gsub(/[^a-z0-9]/, "", w)
      if (length(w) > 5 && w ~ /ing$/) w = substr(w, 1, length(w) - 3)
      else if (length(w) > 4 && w ~ /ed$/) w = substr(w, 1, length(w) - 2)
      else if (length(w) > 4 && w ~ /es$/) w = substr(w, 1, length(w) - 2)
      else if (length(w) > 3 && w ~ /s$/) w = substr(w, 1, length(w) - 1)
      if (length(w) > 4 && w ~ /e$/) w = substr(w, 1, length(w) - 1)
      if (length(w) > 6) w = substr(w, 1, 6)
      return w
    }
    BEGIN { n = split(terms, t, " ") }
    {
      gsub(/[^A-Za-z0-9]+/, " ")
      for (i = 1; i <= NF; i++) {
        w = stem($i)
        if (w != "") seen[w] = 1
        if (w != "" && length($i) >= 4 && $i !~ /^(feat|fix|chore|docs|test|tests|refactor|perf|build)$/ && !(w in tot)) { tot[w] = 1; total++ }
      }
    }
    END {
      c = 0
      for (i = 1; i <= n; i++) {
        w = stem(t[i])
        if (w != "" && (w in seen) && !(w in counted)) {
          counted[w] = 1
          c++
        }
      }
      print c, total + 0
    }'
}

# is_fuzzy_match <title>: at least two shared terms AND at least a third of the
# title's own significant terms, so a long ask cannot match a title by chance.
is_fuzzy_match() {
  local shared total
  read -r shared total <<EOT
$(count_matches "$terms" "$1")
EOT
  [ "$shared" -ge 2 ] && [ $((shared * 3)) -ge "$total" ]
}

# A task id or its branch is a strong direct signal; the fuzzy title signal is
# is_fuzzy_match. One shared term alone is too noisy to warn about.
is_direct_match() {  # <haystack>
  local hay=$1 bare=${BRANCH#fm/}
  if [ "${#ID}" -ge 4 ]; then
    case "$hay" in *"$ID"*) return 0 ;; esac
  fi
  if [ "${#bare}" -ge 4 ]; then
    case "$hay" in *"$bare"*) return 0 ;; esac
  fi
  return 1
}

matched=0
report() {
  matched=$((matched + 1))
  printf 'warning: %s\n' "$1" >&2
}

# run_gh bounds the one network read so a stalled forge cannot hold up a
# dispatch; the timeout is skipped where the host has no timeout(1).
run_gh() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "${FM_PREDISPATCH_TIMEOUT:-10}" "$@"
  else
    "$@"
  fi
}

# Merged pull requests. Only the project's GitHub origin is searched, because
# that is where this fleet's pull requests land; every other origin degrades
# quietly.
origin_url=$(git -C "$PROJECT" config --get remote.origin.url 2>/dev/null || true)
slug=
case "$origin_url" in
  *github.com[:/]*)
    slug=${origin_url#*github.com}
    slug=${slug#[:/]}
    slug=${slug%.git}
    ;;
esac
if [ -n "$slug" ] && command -v gh >/dev/null 2>&1; then
  prs=$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 run_gh gh pr list --repo "$slug" \
    --state merged --limit 100 \
    --json number,title,headRefName,mergedAt,url \
    --jq '.[] | [(.number|tostring), .title, .headRefName, (.mergedAt // ""), .url] | @tsv' 2>/dev/null) || prs=
  shown=0
  while IFS=$'\t' read -r number title head merged_at url; do
    [ -n "$number" ] || continue
    direct=0
    is_direct_match "$head" && direct=1
    if [ "$direct" -eq 1 ] || is_fuzzy_match "$title"; then
      report "task $ID may already be done: merged pull request #$number \"$title\" $url (merged ${merged_at:-unknown})"
      shown=$((shown + 1))
      [ "$shown" -ge 3 ] && break
    fi
  done <<EOF
$prs
EOF
fi

# Recent commits on origin's default branch. The remote-tracking ref is read
# as-is; this check never fetches.
default_branch=$(git -C "$PROJECT" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null || true)
default_branch=${default_branch#origin/}
base_ref=
for candidate in ${default_branch:-} main master; do
  [ -n "$candidate" ] || continue
  if git -C "$PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$candidate" >/dev/null 2>&1; then
    base_ref="refs/remotes/origin/$candidate"
    break
  fi
done
if [ -n "$base_ref" ]; then
  commits=$(git -C "$PROJECT" log -n 200 --format='%h%x09%s' "$base_ref" 2>/dev/null) || commits=
  shown=0
  while IFS=$'\t' read -r sha subject; do
    [ -n "$sha" ] || continue
    direct=0
    if [ "${#ID}" -ge 4 ]; then
      case "$subject" in *"$ID"*) direct=1 ;; esac
    fi
    if [ "$direct" -eq 1 ] || is_fuzzy_match "$subject"; then
      report "task $ID may already be done: recent commit $sha \"$subject\" on ${base_ref#refs/remotes/origin/}"
      shown=$((shown + 1))
      [ "$shown" -ge 3 ] && break
    fi
  done <<EOF
$commits
EOF
fi

if [ "$matched" -gt 0 ]; then
  echo "warning: this is advisory evidence, not a refusal; confirm these are not the same work before relying on this task's worker" >&2
fi

exit 0
