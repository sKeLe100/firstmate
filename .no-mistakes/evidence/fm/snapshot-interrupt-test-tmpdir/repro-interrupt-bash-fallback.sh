#!/usr/bin/env bash
# Manual e2e reproduction for the narrowed interrupt-cleanup assertion.
#
# Part A: interrupt a bounded call running through the fm-timeout-lib.sh bash
#         fallback (the mechanism used on hosts with no timeout/gtimeout/perl)
#         and show the fm-bash-timeout-command.* residue it leaves in TMPDIR -
#         exactly what the old "TMPDIR must be entirely empty" assertion
#         flagged as a snapshot cleanup bug.
# Part B: interrupt a real fm-fleet-snapshot.sh run and show its own
#         fm-fleet-snapshot.* tmpdir IS cleaned up.
# Part C: negative control - plant real snapshot residue, new assertion fires.
set -u
ROOT=$1
old_assert() { # <tmpdir>
  local l; l=$(find "$1" -mindepth 1 2>/dev/null)
  if [ -z "$l" ]; then echo "  OLD (TMPDIR entirely empty): PASS"
  else echo "  OLD (TMPDIR entirely empty): FAIL - 'interrupted snapshot left temp files behind:'"; printf '%s\n' "$l" | sed "s|$1|\$TMPDIR|" | sed 's/^/    /'; fi
}
new_assert() { # <tmpdir>
  local d f; d=$(find "$1" -mindepth 1 -maxdepth 1 -name 'fm-fleet-snapshot.*' -type d 2>/dev/null)
  f=$(find "$1" -mindepth 2 -name 'fm-fleet-snapshot.*' -o -path '*/fm-fleet-snapshot.*/*' 2>/dev/null)
  if [ -n "$d" ]; then echo "  NEW (snapshot-owned only): FAIL - left directory behind: ${d/#$1/\$TMPDIR}"
  elif [ -n "$f" ]; then echo "  NEW (snapshot-owned only): FAIL - left temp files behind: ${f/#$1/\$TMPDIR}"
  else echo "  NEW (snapshot-owned only): PASS - no fm-fleet-snapshot.* residue"; fi
}

work=$(mktemp -d); home=$work/home
mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"

echo "== Part A: bash timeout fallback interrupted mid-flight =="
tmpA=$work/tmpA; mkdir -p "$tmpA"
FM_TIMEOUT_MECHANISM_OVERRIDE=bash TMPDIR="$tmpA" bash -c '
  . '"$ROOT"'/bin/fm-timeout-lib.sh
  echo "  mechanism: $(fm_timeout_mechanism)"
  fm_run_timed 30 sleep 10' &
pid=$!
for _ in $(seq 1 400); do
  [ -n "$(find "$tmpA" -name 'fm-bash-timeout-command.*' -print -quit 2>/dev/null)" ] && break
  sleep 0.02
done
kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
echo "  TMPDIR after interrupt:"; find "$tmpA" -mindepth 1 | sed "s|$tmpA|\$TMPDIR|" | sed 's/^/    /'
old_assert "$tmpA"; new_assert "$tmpA"

echo
echo "== Part B: real fm-fleet-snapshot.sh interrupted mid-run =="
tmpB=$work/tmpB; mkdir -p "$tmpB"
{ printf '## In flight\n\n## Queued\n\n## Done\n'
  for i in $(seq 1 3000); do printf -- '- [x] slow-task-%04d - Synthetic backlog record %04d keeping the snapshot busy long enough to interrupt https://github.com/kunchenguid/firstmate/pull/%d (repo: alpha) (kind: ship) (merged 2026-08-01)\n' "$i" "$i" "$i"; done
} > "$home/data/backlog.md"
TMPDIR="$tmpB" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json >/dev/null 2>&1 &
pid=$!; seen=0
for _ in $(seq 1 2000); do
  if [ -n "$(find "$tmpB" -mindepth 1 -name 'fm-fleet-snapshot.*' -print -quit 2>/dev/null)" ]; then seen=1; break; fi
  kill -0 "$pid" 2>/dev/null || break
done
echo "  snapshot tmpdir observed while running: $seen"
kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
echo "  TMPDIR after interrupt:"; find "$tmpB" -mindepth 1 | sed "s|$tmpB|\$TMPDIR|" | sed 's/^/    /'
new_assert "$tmpB"

echo
echo "== Part C: negative control - plant fm-fleet-snapshot.* residue =="
mkdir -p "$tmpB/fm-fleet-snapshot.CONTROL"; : > "$tmpB/fm-fleet-snapshot.CONTROL/backlog.json"
new_assert "$tmpB"
rm -rf "$work"
