#!/usr/bin/env bash
# bin/fm-questionnaire-refill-source.sh - duplication guard for the
# questionnaire skill's empty-bundle Refill step.
#
# Why: the captain ruled (2026-08-31, questionnaire-skill-design call 2) that
# the empty-bundle fallback must reuse a recent roundtable/roadmap report
# before paying for a fresh Fable project-review scout. This script owns only
# the mechanical recency check (find the newest matching report, print it if
# younger than the freshness window); it does not judge whether that report's
# candidates are still open - the skill reads the report and decides that.
#
# Usage: fm-questionnaire-refill-source.sh [--data-dir <path>] [--max-age-days N]
#   --data-dir <path>   root to search (default: data)
#   --max-age-days N    freshness window in days (default: 3, per the report's
#                        own "duplication guard" and the captain's ruling)
#
# Prints the newest matching report.md path (data/*roundtable*/report.md or
# data/*roadmap*/report.md) with mtime within the window, one line, and exits 0.
# Prints nothing and exits 1 when no report is within the window.
# Exits 2 on a usage error (unknown argument, missing or non-numeric value).
set -euo pipefail

data_dir="data"
max_age_days=3

while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir)
      if [ $# -lt 2 ]; then
        echo "fm-questionnaire-refill-source.sh: --data-dir requires a value" >&2
        exit 2
      fi
      data_dir="$2"
      shift 2
      ;;
    --max-age-days)
      if [ $# -lt 2 ]; then
        echo "fm-questionnaire-refill-source.sh: --max-age-days requires a value" >&2
        exit 2
      fi
      max_age_days="$2"
      shift 2
      ;;
    *)
      echo "fm-questionnaire-refill-source.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$max_age_days" in
  ''|*[!0-9]*)
    echo "fm-questionnaire-refill-source.sh: --max-age-days must be a non-negative integer: $max_age_days" >&2
    exit 2
    ;;
esac

search_root="${data_dir%/}"
if [ -z "$search_root" ]; then
  search_root="/"
  path_prefix=""
else
  path_prefix="$search_root"
fi

if [ ! -d "$data_dir" ]; then
  exit 1
fi

newest=""
newest_mtime=0

while IFS= read -r -d '' report; do
  mtime=$(stat -c '%Y' "$report" 2>/dev/null || stat -f '%m' "$report" 2>/dev/null || echo 0)
  if [ "$mtime" -gt "$newest_mtime" ]; then
    newest_mtime="$mtime"
    newest="$report"
  fi
done < <(find "$search_root" -maxdepth 2 \( -ipath "$path_prefix/*roundtable*/report.md" -o -ipath "$path_prefix/*roadmap*/report.md" \) -print0 2>/dev/null)

if [ -z "$newest" ]; then
  exit 1
fi

now=$(date +%s)
age_days=$(( (now - newest_mtime) / 86400 ))

if [ "$age_days" -ge "$max_age_days" ]; then
  exit 1
fi

echo "$newest"
