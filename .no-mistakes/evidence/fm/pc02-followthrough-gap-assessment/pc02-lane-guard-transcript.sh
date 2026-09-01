#!/usr/bin/env bash
# Evidence driver: shows the real captain-facing CLI behavior of the PC02
# single-lane guard, using the colocated test's fixture helpers.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../../worktrees/4936102b4bcf/01M1F1830V4CQRKJ69YD6MABR1/tests/lib.sh" >/dev/null

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pc02-lane-guard)

make_case() {
  local name=$1 case_dir home proj wt fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *pane_current_command*) printf '%s\n' "${FM_FAKE_PANE_CMD:-firstmate}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_LIST_WINDOWS_ERR:-}" ]; then
      echo "fake inventory failure" >&2
      exit 1
    fi
    printf '%s' "${FM_FAKE_WINDOWS:-}"
    exit 0
    ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  # shellcheck disable=SC2034  # CASE_DIR kept for parity with the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

write_other_meta() {  # <home> <task> <model>
  cat > "$1/state/$2.meta" <<EOF
window=firstmate:fm-$2
endpoint_task_id=$2
harness=opencode
kind=ship
model=$3
EOF
}

run_pc02_spawn() {
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' PATH="$fakebin:$PATH" \
    "$@" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off \
    --model pc02-llamaswap/qwen3.6-35b-a3b-dispatch 2>&1
}

id=pc02-evidence-1
rec=$(make_case evidence "$id"); read_case_record "$rec"
write_other_meta "$HOME_DIR" review-leg-42 pc02-llamaswap/qwen3.8-27b-dispatch

echo "\$ fm-spawn.sh $id <project> --model pc02-llamaswap/qwen3.6-35b-a3b-dispatch   # PC02 lane held by a live task"
run_pc02_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" env FM_FAKE_WINDOWS="fm-review-leg-42
"
echo "exit=$?"
echo "state/$id.meta written? $([ -f "$HOME_DIR/state/$id.meta" ] && echo yes || echo 'no (dispatch falls through to the next candidate)')"
echo

rm -f "$HOME_DIR/state/review-leg-42.meta"
write_other_meta "$HOME_DIR" review-leg-42 pc02-llamaswap/qwen3.8-27b-dispatch
echo "\$ fm-spawn.sh $id <project> --model pc02-llamaswap/qwen3.6-35b-a3b-dispatch   # occupying endpoint positively gone"
run_pc02_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" env FM_FAKE_WINDOWS=""
echo "exit=$?"
echo "state/$id.meta model: $(grep '^model=' "$HOME_DIR/state/$id.meta")"
