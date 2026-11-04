#!/usr/bin/env bash
# Shared fixture builders for the STALLED WAITS live drives.
set -u

ROOT=${ROOT:?}
LAB=${LAB:-}
NOW=${NOW:-$(date +%s)}
CAPTURE="$ROOT/tests/captures/no-mistakes-v1.70.1/parked.toon"

mkrepo() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" -c user.email=fmtest@example.invalid -c user.name=fmtest \
    commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
}

mkfakebin() {
  mkdir -p "$LAB/fakebin"
  # The real recorded `no-mistakes axi status` capture for a run parked at its
  # Test gate (tests/captures/no-mistakes-v1.70.1/parked.toon), rebased onto the
  # fixture worktree's own branch and HEAD so the run binds like the real CLI's
  # answer for that worktree. Every field but branch/head is the capture verbatim.
  cat > "$LAB/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
# A worktree with no .fm-shim-run is a worktree with no run: the CLI answers
# nothing, exactly as it does for a branch no-mistakes is not driving.
emit() {
  local branch head cap
  [ -f "$PWD/.fm-shim-run" ] || return 0
  cap=$(cat "$PWD/.fm-shim-run")
  [ -n "$cap" ] && [ -f "$cap" ] || return 0
  branch=$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=fm/feat-gate
  head=$(git -C "$PWD" rev-parse HEAD 2>/dev/null) || head=deadbeef
  sed -e "s|^  branch:.*|  branch: $branch|" \
      -e "s|^  head:.*|  head: ${head:0:8}|" \
      -e "s|^  head_sha:.*|  head_sha: $head|" \
      "$cap"
}
count_enter() {
  [ -n "${FM_SHIM_COUNT_DIR:-}" ] || return 0
  local n peak
  while ! mkdir "$FM_SHIM_COUNT_DIR/lock" 2>/dev/null; do :; done
  n=$(cat "$FM_SHIM_COUNT_DIR/live")
  n=$((n + 1))
  printf '%s\n' "$n" > "$FM_SHIM_COUNT_DIR/live"
  peak=$(cat "$FM_SHIM_COUNT_DIR/peak")
  [ "$n" -le "$peak" ] || printf '%s\n' "$n" > "$FM_SHIM_COUNT_DIR/peak"
  rmdir "$FM_SHIM_COUNT_DIR/lock"
  sleep "${FM_SHIM_DELAY:-0}"
}
count_leave() {
  [ -n "${FM_SHIM_COUNT_DIR:-}" ] || return 0
  local n
  while ! mkdir "$FM_SHIM_COUNT_DIR/lock" 2>/dev/null; do :; done
  n=$(cat "$FM_SHIM_COUNT_DIR/live")
  printf '%s\n' $((n - 1)) > "$FM_SHIM_COUNT_DIR/live"
  rmdir "$FM_SHIM_COUNT_DIR/lock"
}
case "${1:-}" in
  axi)
    shift
    if [ "$#" = 0 ]; then count_enter; emit; count_leave; exit 0; fi
    case "${1:-}" in
      status) shift; count_enter; emit; count_leave; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  runs) exit 0 ;;
  daemon) printf 'daemon running (pid 4242)\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$LAB/fakebin/no-mistakes"

  # A tmux that never touches a real server: the run-step is authoritative in
  # these fixtures, so the pane read only ever answers "nothing there".
  cat > "$LAB/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# An idle pane on a live endpoint, never a real tmux server: list-windows
# answers this home's recorded window names, display-message a pane target, and
# capture-pane a quiet shell prompt.
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_STATE_OVERRIDE:?}"/*.meta 2>/dev/null ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$LAB/fakebin/tmux"

  cat > "$LAB/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$LAB/fakebin/gh"
}

# Mark this ship's worktree as one no-mistakes is driving (the shim then answers
# with the recorded parked-gate capture for it).
mark_run() {  # <id> [capture-template]
  printf '%s\n' "${2:-$CAPTURE}" > "$LAB/wt/$1/.fm-shim-run"
}

mkship() {  # <id> <branch> [status lines...]
  local id=$1 branch=$2 line
  shift 2
  mkrepo "$LAB/wt/$id" "$branch"
  {
    printf 'kind=ship\n'
    printf 'worktree=%s\n' "$LAB/wt/$id"
    printf 'window=fm:fm-%s\n' "$id"
    printf 'harness=claude\n'
  } > "$LAB/state/$id.meta"
  : > "$LAB/state/$id.status"
  for line in "$@"; do printf '%s\n' "$line" >> "$LAB/state/$id.status"; done
}

# The fixture home, marked as a lab home so the fleet lifecycle entrypoints treat
# it as disposable test ground rather than the operator's fleet.
new_lab() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
  mkfakebin
}

run_drain() {  # <outfile> [VAR=value...]
  local out=$1
  shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
    -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" FM_SHIM_CAPTURE="$CAPTURE" \
    env "$@" "$ROOT/bin/fm-wake-drain.sh" > "$out" 2> "$out.err"
  local rc=$?
  return "$rc"
}
