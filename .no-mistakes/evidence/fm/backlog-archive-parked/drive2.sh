#!/usr/bin/env bash
# Usage: drive2.sh <repo-root>. Owed replies, CRLF, locks, modes, headings, prose edges.
R=$1; B=$(mktemp -d "${TMPDIR:-/tmp}/fm-park2.XXXXXX"); trap 'rm -rf "$B"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
home() { H=$B/$1; mkdir -p $H/data $H/state $H/config; cp $R/.tasks.toml $H/; printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > $H/data/backlog.md; export FM_HOME=$H; cd $H; }
t() { $R/bin/fm-tasks-axi.sh "$@"; }
run() { echo; echo "\$ $*"; "$@" 2>&1 | sed "s#$B#<lab>#g"; echo "[exit ${PIPESTATUS[0]}]"; }
q() { "$@" >/dev/null 2>&1 || echo "SETUP FAILED: $*"; }
sec() { echo; echo "=================== $* ==================="; }

sec "S9 public-followup obligation: refused while owed, parkable once Captain waives"
home pf
jq -n '{request_id:"req-r1",platform:"discord",context_binding:{version:"ctx1",value:"ctx1_req-r1"},public_safe_summary:"owed reply",received_at:"2026-10-01T10:00:00Z",followup_expires_at:"2099-01-01T00:00:00Z",reservation_expires_at:"2099-01-01T00:00:00Z"}' > request.json
jq -n '{type:"pr-merged",project:"firstmate",required_deliverables:["pr_url"],completion_policy:"all-required"}' > expected.json
q tasks-axi public-followup add owed-f1 --request-context-file request.json --purpose promised-final --expected-final-file expected.json --expires-at 2099-02-01T00:00:00Z
run t archive owed-f1
run t archived
q tasks-axi public-followup waive owed-f1 --reason "no longer needed" --approved-by captain
run t archive owed-f1

sec "S10 CRLF backlog, body with a blank paragraph break (byte compare)"
home crlf
printf '%s\r\n' '# Backlog' '' '## Queued' '- [ ] keep-k1 - kept' '- [ ] park-p2 - parked (hold: wait) (hold-kind: parked)' '  para one' '' '  para two' '' '## Done' > data/backlog.md
cp data/backlog.md orig
run t archive park-p2
run od -c data/backlog.md
run cat -A data/backlog-archive.md
run t unarchive park-p2
run cmp orig data/backlog.md

sec "S11 heading variant, title-prose and parent edges"
home heads
printf '# Backlog\n\n## In Flight\n- [ ] fly-a - running\n\n## queued\n- [ ] base-b - base\n- [ ] prose-c - mentions blocked-by: base-b in the title only\n- [ ] kid-d - child parent: base-b\n\n## Done (recent)\n- [x] old-e - old\n' > data/backlog.md
run t archive fly-a
run t archive old-e
run t archive base-b
run t unarchive base-b
run cat data/backlog.md

sec "S12 held and stale locks, file modes, unwritable data dir"
home lk
q t add a-1 one; q t add b-2 two
echo other > data/backlog.md.lock
run t archive a-1
touch -t 202001010000 data/backlog.md.lock
run t archive a-1
run cat data/backlog.md.lock
rm data/backlog.md.lock
chmod 0640 data/backlog.md
run t archive a-1
run stat -c '%a %n' data/backlog.md data/backlog-archive.md
run t unarchive a-1
run stat -c '%a %n' data/backlog.md data/backlog-archive.md
sha256sum data/*.md > $B/sums
chmod 0500 data
run t archive b-2
chmod 0700 data
run sha256sum -c $B/sums
run ls -A data
