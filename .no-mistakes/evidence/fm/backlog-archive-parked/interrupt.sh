#!/usr/bin/env bash
# Usage: interrupt.sh <repo-root>. SIGTERMs real archive runs at staggered delays; also times a bulk move.
R=$1; B=$(mktemp -d "${TMPDIR:-/tmp}/fm-park-int.XXXXXX"); trap 'rm -rf "$B"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
mkdir -p $B/data; cp $R/.tasks.toml $B/; export FM_HOME=$B; cd $B
{ printf '# Backlog\n\n## In flight\n\n## Queued\n'; for i in $(seq 1 60); do echo "- [ ] t$i - item $i (repo: x)"; echo "  body $i"; done; printf '\n## Done\n'; } > orig.md
bad=0; moved=0; untouched=0
for ms in $(seq 100 60 2200); do
  rm -f data/*; cp orig.md data/backlog.md
  timeout -s TERM $(printf '%d.%03d' $((ms/1000)) $((ms%1000))) $R/bin/fm-tasks-axi.sh archive $(seq -f 't%g' 1 20) >/dev/null 2>&1; rc=$?
  sleep_left=$(ls -A data | grep -vE '^backlog(-archive)?\.md$')
  live=$(grep -c '^- \[ \]' data/backlog.md); arch=$(grep -c '^- \[ \]' data/backlog-archive.md 2>/dev/null); arch=${arch:-0}
  echo "TERM after ${ms}ms rc=$rc live=$live archived=$arch leftovers=[${sleep_left}]"
  { [ $((live+arch)) = 60 ] && [ -z "$sleep_left" ] && { [ $arch = 0 ] || [ $arch = 20 ]; }; } || bad=$((bad+1))
done
echo "inconsistent outcomes: $bad"
rm -f data/*; cp orig.md data/backlog.md
S=$(date +%s.%N); $R/bin/fm-tasks-axi.sh archive $(seq -f 't%g' 1 60); echo "60-item archive rc=$? seconds=$(echo "$(date +%s.%N)-$S" | bc)"
S=$(date +%s.%N); $R/bin/fm-tasks-axi.sh unarchive $(seq -f 't%g' 1 60) >/dev/null; echo "60-item unarchive rc=$? seconds=$(echo "$(date +%s.%N)-$S" | bc)"
cmp <(sed '/^$/d' orig.md) <(sed '/^$/d' data/backlog.md) && echo "60-item round trip: identical non-blank lines"
