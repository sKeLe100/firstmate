#!/usr/bin/env bash
set -u
ROOTDIR=$(pwd)
. "$ROOTDIR/tests/lib.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
BASE="$ROOT/bin/.fm-bearings-baseline.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-diff)
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"; mkdir -p "$FM_ROOT_OVERRIDE"; export FM_ROOT_OVERRIDE
. /tmp/fixture-helpers.sh
write_upstream_report() { local home=$1; shift; printf '%s\n' "$@" > "$home/state/.upstream-behind-check.report"; }
OUT=${OUT_DIR:?}
mkdir -p "$OUT"

runv() { # <script> <home> <fakebin> <args...>
  local s=$1 home=$2 fakebin=$3; shift 3
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z NET_LOG="$home/net.log" "$s" "$@" 2>&1
}
norm() { sed -e 's/^generated:.*/generated: <ts>/' -e 's/"generated":"[^"]*"/"generated":"<ts>"/'; }

fails=0
compare() { # <label> <home> <fakebin> <args...>
  local label=$1 home=$2 fakebin=$3; shift 3
  local a b
  a=$(runv "$BASE" "$home" "$fakebin" "$@" | norm)
  b=$(runv "$BEARINGS" "$home" "$fakebin" "$@" | norm)
  if [ "$a" = "$b" ]; then
    printf 'IDENTICAL  %-46s (%s)\n' "$label" "$*"
  else
    printf 'DIFFERENT  %-46s (%s)\n' "$label" "$*"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -20
    fails=$((fails+1))
  fi
  printf '%s\n' "$b" > "$OUT/$label.out"
}

# Scenario 1: standard fixture, no upstream report
h1=$(make_home s1); write_fixture "$h1"; fb1=$(make_fakebin "$h1"); : > "$h1/net.log"
compare no-upstream-toon "$h1" "$fb1"
compare no-upstream-json "$h1" "$fb1" --json
compare no-upstream-alllanded "$h1" "$fb1" --json --all-landed
compare no-upstream-fields "$h1" "$fb1" --json --fields bodies,paths,actions,endpoints
compare no-upstream-alldec "$h1" "$fb1" --all-decisions --all-queued

# Scenario 2: ok upstream report
h2=$(make_home s2); write_fixture "$h2"; fb2=$(make_fakebin "$h2"); : > "$h2/net.log"
write_upstream_report "$h2" "status=ok" "behind=57" "ahead=8" "newest_upstream_date=2026-08-20" \
  "area_count_agents_skills=12" "area_count_bin=9" "area_count_other=3" \
  "skill=bearings" "skill=stow" "skills_total=5" "skills_shown=2" \
  "detail_hint=git -C /home/x log --oneline a..b" "checked_at=1787000000"
compare upstream-ok-toon "$h2" "$fb2"
compare upstream-ok-json "$h2" "$fb2" --json

# Scenario 3: corrupt upstream report
h3=$(make_home s3); write_fixture "$h3"; fb3=$(make_fakebin "$h3"); : > "$h3/net.log"
printf 'not a report\x00garbage\n' > "$h3/state/.upstream-behind-check.report"
compare upstream-corrupt-json "$h3" "$fb3" --json

# Scenario 4: per-home landed cap exceeded
h4=$(make_home s4); write_fixture "$h4"
mate=$(fixture_mate_home "$h4")
{ printf '## In flight\n'; printf '%s\n\n' '- [ ] mate - Decide subscription order (repo: firstmate) (kind: ship) (since 2026-07-11)'; printf '## Done\n'; i=1; while [ $i -le 8 ]; do
    printf -- '- [x] mate-landed-%02d - Secondmate fix %02d (repo: firstmate) (kind: ship) (merged 2026-06-%02d)\n' $i $i $((13-i)); i=$((i+1)); done; } > "$mate/data/backlog.md"
fb4=$(make_fakebin "$h4"); : > "$h4/net.log"
export FM_BEARINGS_LANDED_PER_HOME=2 FM_BEARINGS_LANDED=20
compare percap-json "$h4" "$fb4" --json
compare percap-toon "$h4" "$fb4"
unset FM_BEARINGS_LANDED_PER_HOME FM_BEARINGS_LANDED

echo "differing scenarios: $fails"
