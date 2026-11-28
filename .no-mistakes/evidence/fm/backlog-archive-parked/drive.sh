#!/usr/bin/env bash
# Usage: drive.sh <repo-root>. Drives the parked archive in disposable homes.
R=$1; B=$(mktemp -d "${TMPDIR:-/tmp}/fm-park.XXXXXX"); trap 'rm -rf "$B"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
home() { H=$B/$1; mkdir -p $H/data $H/state $H/config; cp $R/.tasks.toml $H/; printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > $H/data/backlog.md; export FM_HOME=$H; cd $B; }
t() { $R/bin/fm-tasks-axi.sh "$@"; }
run() { echo; echo "\$ $*"; "$@" 2>&1 | sed "s#$B#<lab>#g"; echo "[exit ${PIPESTATUS[0]}]"; }
q() { "$@" >/dev/null 2>&1 || echo "SETUP FAILED: $*"; }
sec() { echo; echo "=================== $* ==================="; }
sums() { sha256sum $H/data/backlog*.md 2>/dev/null | sed "s#$B#<lab>#g"; }

sec "S1 round trip: paused PC02 test + long-idle idea, holds, reasons, blocked-by, body"
home main
q t add infra-a1 "restore PC02 host" --kind ship --repo firstmate
q t add pc02-b2 "PC02 testing, paused" --kind ship --repo firstmate --blocked-by infra-a1 --body $'Line one.\n\nLine three after a blank.'
q t add idea-c3 "long idle idea, with commas, and unicode ✓" --kind scout --repo firstmate
q t add keep-d4 "stays live" --repo firstmate
q t hold pc02-b2 --reason "PC02 testing paused until host returns" --kind parked
q t hold idea-c3 --reason "revisit later" --kind future --until 2027-03-01
cp $H/data/backlog.md $B/orig.md
grep -E '^- .*(pc02-b2|idea-c3)|^  ' $H/data/backlog.md > $B/block.orig
run cat $H/data/backlog.md
run t archive pc02-b2 idea-c3
run cat $H/data/backlog.md
run cat $H/data/backlog-archive.md
run t archived
run tasks-axi show pc02-b2 --file $H/data/backlog-archive.md --full
run tasks-axi show idea-c3 --file $H/data/backlog-archive.md
run t ready
run t unarchive pc02-b2 idea-c3
run t show pc02-b2 --full
run t show idea-c3
run diff <(sort $B/orig.md) <(sort $H/data/backlog.md)
grep -E '^- .*(pc02-b2|idea-c3)|^  ' $H/data/backlog.md > $B/block.after
run diff $B/block.orig $B/block.after
run diff $B/orig.md $H/data/backlog.md

sec "S2 captain hold and its age mark survive parking and a later mark write"
home captain
q $R/bin/fm-captain-hold.sh hold call-e5 --reason "choose the vendor (A or B), see notes" --title "vendor call" --repo firstmate
q t add other-f6 "other" --repo firstmate
q $R/bin/fm-captain-hold.sh mark set call-e5 held-since 2026-10-02
run t show call-e5
run t archive call-e5
run $R/bin/fm-captain-hold.sh mark set other-f6 held-since 2026-11-01
run cat $H/data/task-marks.tsv
run t unarchive call-e5
run t show call-e5
run $R/bin/fm-captain-hold.sh mark get call-e5 held-since
run $R/bin/fm-captain-hold.sh open call-e5

sec "S3 dependency guards (adversarial)"
home deps
q t add base-a "base" ; q t add child-b "child" --blocked-by base-a; q t add other-c "other"
sums
run t archive base-a
sums
run t archive base-a child-b
run t unarchive child-b
sums
run t unarchive child-b base-a
run t show child-b
run t ready

sec "S3b large backlog: dependent beyond row 400 is still seen"
home big
{ printf '# Backlog\n\n## In flight\n\n## Queued\n'; for i in $(seq 1 400); do echo "- [ ] t$i - title, \"quoted\", $i (repo: x)"; done; echo '- [ ] dep-z - last blocked-by: t350 (repo: x)'; printf '\n## Done\n'; } > $H/data/backlog.md
run t archive t350
run t archive t400

sec "S4 refusals: running work, task record, Done, unknown, already-moved, mixed batch"
home refuse
q t add run-a "running"; q t start run-a; q t add meta-b "has record"; : > $H/state/meta-b.meta
q t add fin-c "finished"; q t done fin-c; q t add ok-d "fine"
sums
for id in run-a meta-b fin-c nope-x '../etc'; do run t archive $id; done
run t archive ok-d run-a
sums
run t archive ok-d
run t archive ok-d
run t unarchive meta-b
run t add ok-d "reuse of a parked id"
run t unarchive ok-d

sec "S5 concurrency: parallel archive and tasks-axi writes lose nothing"
home race
for i in $(seq 1 12); do q t add p$i "parked $i"; done
for i in $(seq 1 12); do (t archive p$i >>$B/race.log 2>&1 || echo "archive p$i failed" >>$B/race.log) & (t add n$i "new $i" >>$B/race.log 2>&1 || echo "add n$i failed" >>$B/race.log) & done; wait
echo "failures:"; grep -E 'failed|locked' $B/race.log
echo "live p=$(grep -c '^- \[ \] p' $H/data/backlog.md) n=$(grep -c '^- \[ \] n' $H/data/backlog.md) archived p=$(grep -c '^- \[ \] p' $H/data/backlog-archive.md)"
ls -A $H/data

sec "S6 noncanonical body and bold bullet, shared check with secondmate handoff"
home body
printf '# Backlog\n\n## Queued\n- [ ] tab-a - tabbed\n\tbad line\n- **bold-b** - legacy bold row\n\tbad bold line\n\n## Done\n' > $H/data/backlog.md
sums
run t archive tab-a
run t archive bold-b
sums

sec "S7 record export publishes the parked archive"
home export
q t add parked-x "parked for export"; q t archive parked-x
echo "(export sync)"
printf '%s\n' "$B/exported" > $H/config/record-export-root
run $R/bin/fm-record-export.sh sync
run cat $B/exported/live/data/backlog-archive.md
run t unarchive parked-x

sec "S8 edge shapes: no trailing newline, legacy bold row, symlinked archive, signal-free byte check"
home edge
printf '# Backlog\n\n## Queued\n- [ ] a-1 - one\n- [ ] z-9 - last without newline' > $H/data/backlog.md
cp $H/data/backlog.md $B/edge.orig
run t archive z-9
run t unarchive z-9
run cmp $B/edge.orig $H/data/backlog.md
printf '# Backlog\n\n## Queued\n- **bold-b** - legacy bold row\n  its body\n- [ ] c-2 - two\n\n## Done\n' > $H/data/backlog.md
cp $H/data/backlog.md $B/bold.orig
run t list
run t archive bold-b
run cat $H/data/backlog.md
ln -sf $B/edge.orig $H/data/backlog-archive.md
run t archive c-2
run cat $B/edge.orig
