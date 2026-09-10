#!/usr/bin/env bash
# Operator-level demo of the verified-Codex structured launch guards.
set -u
cd /home/sean_/.no-mistakes/worktrees/4936102b4bcf/01M24VTG2S9E9RRSX0N6W8R658 >/dev/null
. /home/sean_/.no-mistakes/worktrees/4936102b4bcf/01M24VTG2S9E9RRSX0N6W8R658/tests/fixtures.sh
TMP_ROOT=$(fm_test_tmproot fm-codex-guard-demo)
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
chmod +x "$fakebin/timeout"
cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '%s\n' 'codex-cli 0.48.0'
exit 0
SH
chmod +x "$fakebin/codex"
HOME_DIR=$TMP_ROOT/home; PROJ=$TMP_ROOT/project; WT=$TMP_ROOT/wt; LOG=$TMP_ROOT/launch.log
fm_test_spawn_home "$HOME_DIR" codex >/dev/null
fm_git_worktree "$PROJ" "$WT" wt-demo >/dev/null
fm_test_spawn_brief "$HOME_DIR" demo-a >/dev/null

write_codex_meta() {
  cat > "$HOME_DIR/state/$1.meta" <<EOF
window=firstmate:fm-$1
endpoint_task_id=$1
harness=codex
kind=$2
model=gpt-5
effort=high
backend=unverified-test-backend
EOF
}
path_without_codex() {
  local dir out="" s=$IFS; IFS=:
  for dir in $PATH; do IFS=$s; [ -n "$dir" ] || dir=.; [ ! -x "$dir/codex" ] || { IFS=:; continue; }; out="${out:+$out:}$dir"; IFS=:; done
  IFS=$s; printf '%s\n' "$out"
}
spawn() { : > "$LOG"; CLAUDE_CONFIG_DIR= FM_FAKE_LAUNCH_LOG="$LOG" fm_test_run_spawn "$HOME_DIR" "$WT" "$fakebin" "$@" | grep -v 'launch-brief.md records no delivery contract'; return "${PIPESTATUS[0]}"; }

echo "=== 1. verified codex ship spawn: resolved binary is what actually launches, path+version recorded as audit metadata ==="
printf 'config/codex-lane-cap = %s\n' "$(cat "$HOME_DIR/config/codex-lane-cap")"
spawn demo-a "$PROJ" --harness codex --model gpt-5 --effort high --mode no-mistakes --yolo off; echo "exit=$?"
echo '-- launch command sent to the pane --'; cat "$LOG"
echo '-- audit metadata on the task --'; grep -E '^(harness|model|effort|codex_exe|codex_version)=' "$HOME_DIR/state/demo-a.meta"

echo; echo "=== 2. lane cap: worker+scout lanes count, secondmate supervisors do not ==="
printf '2\n' > "$HOME_DIR/config/codex-lane-cap"
write_codex_meta live-ship ship; write_codex_meta live-scout scout
echo '-- cap 2 with one live ship + one live scout --'
spawn demo-a "$PROJ" --harness codex --model gpt-5 --effort high --mode no-mistakes --yolo off; echo "exit=$?"
rm -f "$HOME_DIR/state/live-scout.meta"; write_codex_meta live-2nd secondmate
echo '-- same cap, the scout replaced by a codex secondmate supervisor --'
spawn demo-a "$PROJ" --harness codex --model gpt-5 --effort high --mode no-mistakes --yolo off; echo "exit=$?"

echo; echo "=== 3. missing / malformed cap policy fails closed ==="
rm -f "$HOME_DIR/state/live-ship.meta" "$HOME_DIR/state/live-2nd.meta" "$HOME_DIR/config/codex-lane-cap"
spawn demo-a "$PROJ" --harness codex --model gpt-5 --effort high --mode no-mistakes --yolo off; echo "exit=$?"
for v in 0 -1 nope; do printf '%s\n' "$v" > "$HOME_DIR/config/codex-lane-cap"
  echo "-- cap file contains '$v' --"; spawn demo-a "$PROJ" --harness codex --model gpt-5 --effort high --mode no-mistakes --yolo off; echo "exit=$?"; done
printf '2\n' > "$HOME_DIR/config/codex-lane-cap"

echo; echo "=== 4. codex executable rediscovery: absent, unprobeable, and silent binaries all refuse before launch ==="
echo '-- codex absent from PATH --'
(PATH=$(path_without_codex); rm -f "$fakebin/codex"; spawn demo-a "$PROJ" --harness codex --model gpt-5 --effort high --mode no-mistakes --yolo off; echo "exit=$?")
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && exit 3\nexit 0\n' > "$fakebin/codex"; chmod +x "$fakebin/codex"
echo '-- codex --version exits nonzero --'
spawn demo-a "$PROJ" --harness codex --model gpt-5 --effort high --mode no-mistakes --yolo off; echo "exit=$?"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/codex"; chmod +x "$fakebin/codex"
echo '-- codex --version prints nothing --'
spawn demo-a "$PROJ" --harness codex --model gpt-5 --effort high --mode no-mistakes --yolo off; echo "exit=$?"
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && printf "%%s\\n" "codex-cli 0.48.0"\nexit 0\n' > "$fakebin/codex"; chmod +x "$fakebin/codex"

echo; echo "=== 5. explicit model/effort still required; no fast-service override in the structured template ==="
spawn demo-a "$PROJ" --harness codex --model gpt-5 --effort max --mode no-mistakes --yolo off; echo "exit=$?"
spawn demo-a "$PROJ" --harness codex --effort high --mode no-mistakes --yolo off; echo "exit=$?"

echo; echo "=== 6. raw shell launches are refused for routine dispatch and confined to the unverified scout-only lab ==="
spawn demo-a "$PROJ" "codex --dangerously-bypass-approvals-and-sandbox" --mode no-mistakes --yolo off; echo "exit=$?"
spawn demo-a "$PROJ" "codex --dangerously-bypass-approvals-and-sandbox" --relaunch --adapter-verification; echo "exit=$?"
spawn demo-a "$PROJ" "codex --dangerously-bypass-approvals-and-sandbox" --secondmate --adapter-verification; echo "exit=$?"
echo '-- allowed only as a scout adapter-verification trial --'
spawn demo-a "$PROJ" "codex --dangerously-bypass-approvals-and-sandbox" --scout --adapter-verification; echo "exit=$?"
echo '-- launched verbatim, unverified, with no codex policy applied --'; cat "$LOG"
