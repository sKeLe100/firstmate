#!/usr/bin/env bash
# fm-lint-budget.sh - lint-time budget guard for one CI lint partition.
#
# Reads wall_seconds from a bin/fm-lint.sh --telemetry snapshot and compares it
# with the partition job's cap (timeout-minutes). It emits a GitHub
# ::warning:: at or above 50 percent of the cap and an ::error:: with a failing
# exit at or above 70 percent, so a lint slowdown surfaces weeks before the cap
# cancels the job. The cap is read from the workflow job itself with
# --workflow/--job, keeping the job's timeout-minutes the one place it is
# written; --cap-minutes passes it directly instead.
#
# Usage:
#   fm-lint-budget.sh --telemetry <tsv> --workflow <yml> --job <id>
#   fm-lint-budget.sh --telemetry <tsv> --cap-minutes <minutes>
#   fm-lint-budget.sh --help
#
# Exit status: 0 within budget or warned, 1 over the failure threshold, 2 on a
# usage error or an unreadable telemetry snapshot or cap.
set -u

WARN_PERCENT=50
FAIL_PERCENT=70

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/fm-lint-budget.sh"

fm_lint_budget_usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$SELF"
}

fm_lint_budget_die() {
  printf '::error title=Lint time budget::fm-lint-budget.sh: %s\n' "$1"
  exit 2
}

TELEMETRY=
WORKFLOW=
JOB=
CAP_MINUTES=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --telemetry|--workflow|--job|--cap-minutes)
      [ "$#" -ge 2 ] || fm_lint_budget_die "$1 requires a value."
      case "$1" in
        --telemetry) TELEMETRY=$2 ;;
        --workflow) WORKFLOW=$2 ;;
        --job) JOB=$2 ;;
        --cap-minutes) CAP_MINUTES=$2 ;;
      esac
      shift 2
      ;;
    --help|-h)
      fm_lint_budget_usage
      exit 0
      ;;
    *) fm_lint_budget_die "unknown argument: $1" ;;
  esac
done

[ -n "$TELEMETRY" ] || fm_lint_budget_die "--telemetry is required."
if [ -n "$WORKFLOW" ] || [ -n "$JOB" ]; then
  [ -z "$CAP_MINUTES" ] || fm_lint_budget_die "pass either --cap-minutes or --workflow with --job, not both."
  [ -n "$WORKFLOW" ] && [ -n "$JOB" ] || fm_lint_budget_die "--workflow and --job go together."
  command -v ruby >/dev/null 2>&1 || fm_lint_budget_die "ruby is required to read the cap from $WORKFLOW."
  CAP_MINUTES=$(ruby -ryaml -e '
    puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes")
  ' "$WORKFLOW" "$JOB" 2>/dev/null) || fm_lint_budget_die "could not read jobs.$JOB.timeout-minutes from $WORKFLOW."
fi
case "$CAP_MINUTES" in
  ''|*[!0-9]*|0) fm_lint_budget_die "the cap must be a positive whole number of minutes, got '$CAP_MINUTES'." ;;
esac

[ -r "$TELEMETRY" ] || fm_lint_budget_die "telemetry snapshot not readable: $TELEMETRY"
WALL=$(awk -F '\t' '$1 == "wall_seconds" { print $2; exit }' "$TELEMETRY")
case "$WALL" in
  ''|*[!0-9]*) fm_lint_budget_die "telemetry snapshot has no whole wall_seconds: $TELEMETRY" ;;
esac

CAP_SECONDS=$((CAP_MINUTES * 60))
PERCENT=$((WALL * 100 / CAP_SECONDS))
SUMMARY="lint took ${WALL}s, ${PERCENT}% of the ${CAP_MINUTES}-minute job cap (warn at ${WARN_PERCENT}%, fail at ${FAIL_PERCENT}%)"
if [ $((WALL * 100)) -ge $((CAP_SECONDS * FAIL_PERCENT)) ]; then
  printf '::error title=Lint time budget::%s\n' "$SUMMARY"
  exit 1
fi
if [ $((WALL * 100)) -ge $((CAP_SECONDS * WARN_PERCENT)) ]; then
  printf '::warning title=Lint time budget::%s\n' "$SUMMARY"
  exit 0
fi
printf 'fm-lint-budget.sh: %s\n' "$SUMMARY"
