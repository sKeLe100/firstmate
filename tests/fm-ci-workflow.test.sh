#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR while main pushes are never
# cancelled, and every CI job carries a finite hang tripwire drawn from the
# three-tier timeout policy that docs/fm-test-portable-shards.md "Timeouts"
# owns (fast, normal, heavy), so no job drifts back to a one-off number.
#
# They also hold the fork opt-out: FM_CI_SKIP_PUSH skips push jobs through
# job-level conditions, while the fork keeps the macOS job removed.
#
# The workflow is parsed as YAML and its concurrency and job-level `if`
# expressions are resolved against simulated pull_request and push contexts,
# so the assertions describe what GitHub would do, not how the file happens
# to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Evaluate the subset of GitHub's expression language that ci.yml uses -
# string literals, context lookups, the status functions, !, ==, !=, &&,
# ||, and parentheses - against a simulated context hash, following the
# documented operator precedence, the case-insensitive string comparison, and
# the `a || b` fallback that returns the first truthy operand rather than a
# boolean. The status functions read the simulated outcome of the needed jobs
# from the context key "needs.status" (success, failure, or cancelled), which
# defaults to success. Each ruby -e below prepends this so every resolver shares one
# evaluator.
# shellcheck disable=SC2016  # the ${{ }} below is Ruby text, not a shell expansion
EXPRESSION_RUBY='
require "strscan"
class Expression
  def self.evaluate(source, context)
    new(source, context).parse
  end

  STATUS_FUNCTIONS = %w[always() success() failure() cancelled()].freeze

  # A job or step `if` is a bare expression or one wrapped in ${{ }}, an
  # absent condition means the job runs, and a condition that calls no status
  # function gets the implicit success() check GitHub documents.
  def self.condition(raw, context)
    source = raw.to_s.strip
    source = Regexp.last_match(1) if source =~ /\A\$\{\{(.*)\}\}\z/m
    source = "success()" if source.empty?
    source = "success() && (#{source})" unless new(source, context).status_check?
    truthy?(evaluate(source, context))
  end

  # A result is truthy unless it is false, nil, or the empty string.
  def self.truthy?(value)
    value != false && !value.nil? && value != ""
  end

  def initialize(source, context)
    @context = context
    @tokens = []
    scanner = StringScanner.new(source)
    until scanner.eos?
      next if scanner.skip(/\s+/)
      if scanner.scan(/\x27([^\x27]*)\x27/) then @tokens << [:string, scanner[1]]
      elsif scanner.scan(/\|\||&&|==|!=|[()!]/) then @tokens << [:operator, scanner.matched]
      elsif scanner.scan(/[A-Za-z_][\w.\-]*(?:\(\))?/) then @tokens << [:name, scanner.matched]
      else raise "unsupported expression syntax at: #{scanner.rest}"
      end
    end
  end

  def status_check?
    @tokens.any? { |kind, value| kind == :name && STATUS_FUNCTIONS.include?(value) }
  end

  def parse
    result = parse_or
    raise "unexpected trailing token: #{@tokens.first.inspect}" unless @tokens.empty?
    result
  end

  private

  def take?(operator)
    return false unless @tokens.first == [:operator, operator]
    @tokens.shift
    true
  end

  def parse_or
    left = parse_and
    while take?("||")
      right = parse_and
      left = Expression.truthy?(left) ? left : right
    end
    left
  end

  def parse_and
    left = parse_comparison
    while take?("&&")
      right = parse_comparison
      left = Expression.truthy?(left) ? right : left
    end
    left
  end

  def parse_comparison
    left = parse_unary
    loop do
      operator = ["==", "!="].find { |candidate| take?(candidate) } or break
      right = parse_unary
      unless left.class == right.class
        raise "the resolver only compares operands of one type: #{left.inspect} #{operator} #{right.inspect}"
      end
      equal = left.is_a?(String) ? left.casecmp?(right) : left == right
      left = operator == "==" ? equal : !equal
    end
    left
  end

  def parse_unary
    return !Expression.truthy?(parse_unary) if take?("!")
    parse_primary
  end

  def parse_primary
    if take?("(")
      inner = parse_or
      raise "missing closing parenthesis" unless take?(")")
      return inner
    end
    kind, value = @tokens.shift
    raise "expected an operand, got #{kind.inspect}" unless kind == :string || kind == :name
    return value if kind == :string
    if STATUS_FUNCTIONS.include?(value)
      status = @context.fetch("needs.status", "success")
      return value == "always()" || value == "#{status}()"
    end
    raise "unresolvable context reference: #{value}" unless @context.key?(value)
    @context.fetch(value)
  end
end
'

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>".
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
}

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { Expression.evaluate(Regexp.last_match(1), context).to_s }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id"
}

# Print, one per line in workflow order, the jobs whose job-level `if`
# resolves true under one simulated event and fork variable setting; an unset
# repository variable reads as the empty string, as GitHub documents.
jobs_running_under() {  # <event> <FM_CI_SKIP_PUSH>
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
context = {
  "github.event_name" => ARGV[1],
  "vars.FM_CI_SKIP_PUSH" => ARGV[2],
}
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  puts name if Expression.condition(job["if"], context)
end
' "$CI_WORKFLOW" "$1" "$2"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

# Tier membership is the executable inventory of the timeout policy: a new job
# must join a tier, and a job-level value outside these tiers is exactly the
# one-off number the policy removed.
FAST_TIER_JOBS='lint-aggregate test-coverage invariants tests-timing-aggregate'
NORMAL_TIER_JOBS='tests-portable-parallel-1 tests-portable-parallel-2'
HEAVY_TIER_JOBS='tests-herdr'
# Fork overrides of the normal tier, each pinned by
# test_fork_overrides_keep_their_caps; the fork removed macos-stock-bash.
FORK_OVERRIDE_JOBS='lint tests-portable-serial'

# Print the one timeout every listed job shares; fail on any disagreement.
tier_timeout() {  # <tier> <job>...
  local tier=$1 job first actual
  shift
  first=
  for job in "$@"; do
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    case "$actual" in ''|*[!0-9]*) fail "$job ($tier tier) has no integer timeout, got $actual" ;; esac
    if [ -z "$first" ]; then
      first=$actual
    elif [ "$actual" != "$first" ]; then
      fail "$tier tier jobs must share one timeout, got $first and $actual ($job)"
    fi
  done
  printf '%s\n' "$first"
}

# Print every job id in the workflow, one per line.
workflow_jobs() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("jobs").keys' "$CI_WORKFLOW"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$CI_WORKFLOW") || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

# Every job sits in exactly one tier or the fork override list, and the tiers
# carry exactly three distinct job-level timeouts: one per tier, no one-off
# numbers outside the named fork overrides.
test_every_job_belongs_to_exactly_one_timeout_tier() {
  local expected actual distinct
  # shellcheck disable=SC2086
  expected=$(printf '%s\n' $FAST_TIER_JOBS $NORMAL_TIER_JOBS $HEAVY_TIER_JOBS $FORK_OVERRIDE_JOBS | LC_ALL=C sort)
  [ "$(printf '%s\n' "$expected" | LC_ALL=C sort -u)" = "$expected" ] \
    || fail "a job is listed in more than one timeout tier:"$'\n'"$expected"
  actual=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  [ "$actual" = "$expected" ] \
    || fail "ci.yml jobs and the timeout tiers disagree; every job must join one tier"$'\n'"workflow: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"tiers: $(printf '%s' "$expected" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  distinct=$(for job in $FAST_TIER_JOBS $NORMAL_TIER_JOBS $HEAVY_TIER_JOBS; do job_timeout "$job"; done | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$distinct" = 3 ] \
    || fail "ci.yml tiers must carry exactly three distinct job timeouts (fast, normal, heavy), got $distinct"
  pass "every ci.yml job belongs to one of the three timeout tiers or a named fork override"
}

# The fork's measured overrides of the normal tier stay pinned (ci.yml owns the
# measurements, docs/fm-test-portable-shards.md "Timeouts" owns the policy).
test_fork_overrides_keep_their_caps() {
  local job expected actual
  while read -r job expected; do
    [ -n "$job" ] || continue
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    [ "$actual" = "$expected" ] \
      || fail "$job timeout must stay $expected minutes, got $actual"
  done <<'CAPS'
lint 45
tests-portable-serial 40
CAPS
  pass "the fork's measured normal-tier overrides keep their caps"
}

# Fast tier: seconds-long checks share one short tripwire in the 5-10 minute band.
test_fast_tier_shares_one_short_tripwire() {
  local fast
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  [ "$fast" -ge 5 ] && [ "$fast" -le 10 ] \
    || fail "fast tier must be a 5-10 minute hang tripwire, got $fast"
  pass "fast tier jobs share one $fast minute tripwire"
}

# Normal tier: every test or lint lane shares ONE fixed 30-minute budget,
# above the fast tier. That budget is a hang tripwire, not a packing estimate.
test_normal_tier_shares_one_budget() {
  local fast normal
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  [ "$normal" -gt "$fast" ] \
    || fail "normal tier ($normal) must exceed the fast tier ($fast)"
  [ "$normal" = 30 ] \
    || fail "normal tier must be the single 30-minute shared budget, got $normal"
  pass "normal tier jobs share one $normal minute budget"
}

# Heavy tier: Herdr alone carries a job-level last-resort backstop above the
# normal tier, while its family-run step owns a tighter tripwire so the
# always() cleanup and timing upload still run after a hang.
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop() {
  local normal heavy step
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  heavy=$(tier_timeout heavy $HEAVY_TIER_JOBS) || exit 1
  [ "$heavy" -gt "$normal" ] \
    || fail "heavy tier backstop ($heavy) must exceed the normal tier ($normal)"
  [ "$heavy" -ge 60 ] && [ "$heavy" -le 75 ] \
    || fail "heavy tier backstop must stay a 60-75 minute last resort, got $heavy"
  step=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("steps")
index = steps.index { |s| s["id"] == "run-real-herdr-family" }
raise "no run-real-herdr-family step" unless index
teardown = steps.index { |s| s["id"] == "cleanup-herdr-lab-sessions" }
raise "no cleanup-herdr-lab-sessions step" unless teardown
raise "teardown must follow the family-run step" unless teardown > index
raise "teardown must run under always()" unless steps[teardown]["if"].to_s.strip == "always()"
puts steps[index].fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" tests-herdr) || fail "could not read the Herdr family-run step"
  case "$step" in ''|*[!0-9]*) fail "the Herdr family-run step needs its own timeout-minutes, got $step" ;; esac
  [ "$step" = 20 ] \
    || fail "the Herdr family-run step must be the 20-minute tripwire, got $step"
  [ "$step" -lt "$heavy" ] \
    || fail "the Herdr step tripwire ($step) must stay below the job backstop ($heavy)"
  pass "Herdr keeps a $step minute step tripwire under a $heavy minute job backstop"
}

# The fork keeps macOS removed. The push opt-out affects only retained jobs
# on push events, leaving every pull-request check active.
test_fork_skip_variables_are_opt_in() {
  local all event skip_push expected want actual
  all=$(workflow_jobs) || fail "could not list ci.yml jobs"
  printf '%s\n' "$all" | grep -qx macos-stock-bash \
    && fail "the fork's removed macOS job was restored"
  while read -r event skip_push expected; do
    [ "$skip_push" != - ] || skip_push=
    case $expected in
      all) want=$all ;;
      none) want= ;;
      *) fail "unknown expectation $expected" ;;
    esac
    actual=$(jobs_running_under "$event" "$skip_push") \
      || fail "could not resolve the job conditions for $event FM_CI_SKIP_PUSH=$skip_push"
    [ "$actual" = "$want" ] \
      || fail "$event with FM_CI_SKIP_PUSH=$skip_push must run $expected jobs"$'\n'"ran: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"wanted: $(printf '%s' "$want" | tr '\n' ' ')"
  done <<'TABLE'
push         - all
pull_request - all
push         1 none
pull_request 1 all
push         0 all
pull_request 0 all
TABLE
  pass "the fork retains macOS removal and skips only push jobs when opted in"
}

# Print true or false: whether one job's job-level `if` resolves true under
# one simulated event, fork variable setting, and outcome of its needed jobs.
job_runs_under() {  # <job> <event> <FM_CI_SKIP_PUSH> <needs status>
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
context = {
  "github.event_name" => ARGV[2],
  "vars.FM_CI_SKIP_PUSH" => ARGV[3],
  "needs.status" => ARGV[4],
}
puts Expression.condition(YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1])["if"], context)
' "$CI_WORKFLOW" "$@"
}

# The aggregate must keep running after a failed lane so its timing summary
# still lands, while the push skip still removes it from a skipped push run.
test_timing_aggregate_still_runs_after_a_failed_lane() {
  local event skip_push expected actual
  while read -r event skip_push expected; do
    [ "$skip_push" != - ] || skip_push=
    actual=$(job_runs_under tests-timing-aggregate "$event" "$skip_push" failure) \
      || fail "could not resolve the aggregate condition for $event FM_CI_SKIP_PUSH=$skip_push"
    [ "$actual" = "$expected" ] \
      || fail "after a failed lane, the aggregate on $event with FM_CI_SKIP_PUSH=$skip_push must resolve $expected, got $actual"
  done <<'TABLE'
pull_request - true
push         - true
push         1 false
TABLE
  pass "the timing aggregate still runs after a failed lane unless the push run is skipped"
}

# The one required Lint check aggregates every partition: it must still run
# after a failed or cancelled partition and fail unless all of them succeeded,
# so a cancelled partition can never leave lint green or unreported.
test_lint_aggregate_fails_unless_every_partition_succeeded() {
  local tmp status actual result rc
  tmp=$(fm_test_tmproot fm-ci-lint-aggregate)
  # shellcheck disable=SC2016 # the ${{ }} below is Ruby text, not a shell expansion
  ruby -ryaml -e '
job = YAML.load_file(ARGV[0]).fetch("jobs").fetch("lint-aggregate")
raise "the aggregate must be named Lint" unless job.fetch("name") == "Lint"
raise "the aggregate must need every lint partition" unless Array(job.fetch("needs")) == ["lint"]
steps = job.fetch("steps")
raise "the aggregate needs exactly one step" unless steps.length == 1
step = steps.first
raise "the aggregate must read needs.lint.result" unless step.fetch("env").fetch("LINT_RESULT").strip == "${{ needs.lint.result }}"
File.write(ARGV[1], step.fetch("run"))
' "$CI_WORKFLOW" "$tmp/aggregate.sh" || fail "could not read the Lint aggregate job"
  for status in failure cancelled; do
    actual=$(job_runs_under lint-aggregate pull_request '' "$status") \
      || fail "could not resolve the Lint aggregate condition after $status"
    [ "$actual" = true ] || fail "the Lint aggregate must still run after a $status partition, got $actual"
  done
  [ "$(job_runs_under lint-aggregate push 1 success)" = false ] \
    || fail "the Lint aggregate must follow the push skip like its partitions"
  while read -r result expected; do
    rc=0
    LINT_RESULT=$result bash "$tmp/aggregate.sh" > "$tmp/out" 2>&1 || rc=$?
    case "$expected" in
      pass) [ "$rc" -eq 0 ] || fail "the Lint aggregate failed on partition result $result: $(cat "$tmp/out")" ;;
      fail) [ "$rc" -ne 0 ] || fail "the Lint aggregate passed on partition result $result" ;;
    esac
  done <<'TABLE'
success pass
failure fail
cancelled fail
skipped fail
TABLE
  pass "the Lint aggregate runs after any partition outcome and passes only when every partition succeeded"
}

# Each partition checks its own wall time against the lint job's cap, read
# from that job's timeout-minutes so the cap is written once. The step's
# script runs here against fixture telemetry scaled from the workflow's real
# cap: quiet under 50 percent, a warning from 50, a failure from 70, and the
# step itself still runs after a failed lint step.
test_lint_partitions_check_their_time_budget() {
  local tmp cap_seconds wall rc expected run_after_failure
  tmp=$(fm_test_tmproot fm-ci-lint-budget)
  # shellcheck disable=SC2016 # the ${{ }} below is Ruby text, not a shell expansion
  cap_seconds=$(ruby -ryaml -e '
job = YAML.load_file(ARGV[0]).fetch("jobs").fetch("lint")
steps = job.fetch("steps")
lint = steps.index { |s| s["run"].to_s.include?("bin/fm-lint.sh") }
budget = steps.index { |s| s["run"].to_s.include?("bin/fm-lint-budget.sh") }
raise "no lint step" unless lint
raise "no budget step after the lint step" unless budget && budget > lint
File.write(ARGV[1], steps[budget].fetch("run").gsub("${{ matrix.partition }}", "1"))
File.write(ARGV[2], steps[budget]["if"].to_s)
puts job.fetch("timeout-minutes") * 60
' "$CI_WORKFLOW" "$tmp/budget.sh" "$tmp/budget.if") \
    || fail "could not read the lint time-budget step"
  mkdir -p "$tmp/runner/fm-lint"
  while read -r wall expected; do
    printf 'wall_seconds\t%s\n' $((cap_seconds * wall / 100)) > "$tmp/runner/fm-lint/partition-1.tsv"
    rc=0
    (cd "$ROOT" && RUNNER_TEMP="$tmp/runner" bash "$tmp/budget.sh") > "$tmp/out" 2>&1 || rc=$?
    case "$expected" in
      quiet)
        if [ "$rc" -ne 0 ] || grep -q '^::' "$tmp/out"; then
          fail "the budget step must stay quiet at $wall% of the cap (rc=$rc): $(cat "$tmp/out")"
        fi ;;
      warn)
        if [ "$rc" -ne 0 ] || ! grep -q '^::warning' "$tmp/out"; then
          fail "the budget step must warn without failing at $wall% of the cap (rc=$rc): $(cat "$tmp/out")"
        fi ;;
      fail)
        if [ "$rc" -eq 0 ] || ! grep -q '^::error' "$tmp/out"; then
          fail "the budget step must fail at $wall% of the cap (rc=$rc): $(cat "$tmp/out")"
        fi ;;
    esac
  done <<'TABLE'
10 quiet
49 quiet
50 warn
69 warn
70 fail
100 fail
TABLE
  run_after_failure=$(ruby -ryaml -e "$EXPRESSION_RUBY" -e '
puts Expression.condition(File.read(ARGV[0]), { "needs.status" => "failure" })
' "$tmp/budget.if") || fail "could not resolve the budget step condition"
  [ "$run_after_failure" = true ] \
    || fail "the budget step must still run after a failed lint step, got $run_after_failure"
  pass "each lint partition warns at 50% and fails at 70% of the lint job cap, even after lint findings"
}

test_ci_matrices_match_executable_partitions() {
  ruby -ryaml -ropen3 - "$CI_WORKFLOW" "$ROOT" <<'RUBY' || fail "CI partition contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
root = ARGV[1]
serial = jobs.fetch("tests-portable-serial").fetch("strategy")
raise "serial failures must not cancel other shards" unless serial.fetch("fail-fast") == false
matrix = serial.fetch("matrix")
raise "unexpected serial dimensions" unless matrix.keys == ["shard"]
shards = matrix.fetch("shard")
lanes, status = Open3.capture2(File.join(root, "bin/fm-test-run.sh"), "--list-lanes")
raise "cannot list runner lanes" unless status.success?
actual = lanes.lines.map(&:strip).select { |l| l.match?(/\Aportable-serial-\d+of\d+\z/) }
expected = shards.map { |s| "portable-serial-#{s}of#{shards.length}" }
raise "CI matrix and runner disagree" unless actual.sort == expected.sort
lint = jobs.fetch("lint").fetch("strategy")
raise "lint failures must not cancel another partition" unless lint.fetch("fail-fast") == false
matrix = lint.fetch("matrix")
raise "unexpected lint dimensions" unless matrix.keys == ["partition"]
parts = matrix.fetch("partition")
roots = parts.flat_map do |p|
  output, result = Open3.capture2(File.join(root, "bin/fm-lint.sh"), "--partition", "#{p}of#{parts.length}", "--list-files")
  raise "unsupported lint partition" unless result.success?
  output.lines.map(&:strip)
end
canonical, result = Open3.capture2({"CI" => "true"}, File.join(root, "bin/fm-lint.sh"), "--list-files")
raise "lint matrix loses or duplicates canonical roots" unless result.success? && roots.sort == canonical.lines.map(&:strip).sort
RUBY
  pass "CI matrices cover every executable serial lane and canonical lint root exactly once"
}

test_ci_matrices_match_executable_partitions
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_fork_skip_variables_are_opt_in
test_timing_aggregate_still_runs_after_a_failed_lane
test_lint_aggregate_fails_unless_every_partition_succeeded
test_lint_partitions_check_their_time_budget
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fork_overrides_keep_their_caps
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
