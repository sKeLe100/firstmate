#!/usr/bin/env bash
# Failure diagnostics, per-case tracing, and bounded fixture waits shared by the
# long captain-hold lifecycle test and its fast contract test.

fm_test_preserve_diagnostics() {
  local rc=$1 stamp dest last_command=$FM_TEST_LAST_COMMAND
  trap - DEBUG
  [ "$rc" -eq 0 ] && return 0
  [ -z "${FM_TEST_DIAGNOSTICS_DONE:-}" ] || return 0
  FM_TEST_DIAGNOSTICS_DONE=1
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  dest="$DIAGNOSTIC_ROOT/failure-$stamp-$$"
  mkdir -p "$dest" || return 0
  {
    printf 'exit_status=%s\nactive_case=%s\nlast_command=%s\n' \
      "$rc" "$FM_TEST_ACTIVE_CASE" "$last_command"
    printf 'fixture_root=%s\n' "$TMP_ROOT"
    printf 'fixture_child_pids='; jobs -pr | tr '\n' ' '; printf '\n'
    printf 'fixture_lock_files:\n'
    find "$TMP_ROOT" -type f \( -name '*.lock' -o -name '.control-*' \) -print 2>/dev/null || true
    printf 'fixture_open_fds:\n'
    for fd in /proc/"$$"/fd/*; do
      target=$(readlink "$fd" 2>/dev/null || true)
      case "$target" in "$TMP_ROOT"/*) printf '%s -> %s\n' "$fd" "$target" ;; esac
    done
  } > "$dest/diagnostic.txt"
  cp "$CASE_TRACE" "$dest/cases.tsv" 2>/dev/null || true
  printf 'failure diagnostic: %s\n' "$dest" >&2
}

fm_test_finish() {  # <exit status>
  fm_test_preserve_diagnostics "$1" || true
  fm_test_cleanup
}

fm_test_install_exit_traps() {
  trap 'fm_test_finish $?' EXIT
  trap 'fm_test_finish 130; exit 130' INT
  trap 'fm_test_finish 143; exit 143' TERM
  trap 'fm_test_finish 129; exit 129' HUP
  trap 'fm_test_finish 131; exit 131' QUIT
}

run_case() {  # <case function>
  local case_name=$1 start end rc
  start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  FM_TEST_ACTIVE_CASE=$case_name
  printf '%s\tstart\t%s\n' "$case_name" "$start" >> "$CASE_TRACE"
  printf 'FM_TEST_CASE_BEGIN %s %s\n' "$start" "$case_name"
  "$case_name"
  rc=$?
  end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\tend\t%s\t%s\n' "$case_name" "$end" "$rc" >> "$CASE_TRACE"
  printf 'FM_TEST_CASE_END %s %s rc=%s\n' "$end" "$case_name" "$rc"
  FM_TEST_ACTIVE_CASE=between-cases
  return "$rc"
}

bounded_fixture_wait() {  # <pid> <description> [deadline seconds]
  local pid=$1 description=$2 deadline=${3:-60} elapsed=0
  while jobs -r -p | grep -Fxq "$pid"; do
    if [ "$elapsed" -ge "$((deadline * 10))" ]; then
      printf 'not ok - timed out after %ss waiting for %s (pid %s)\n' \
        "$deadline" "$description" "$pid" >&2
      FM_TEST_LAST_COMMAND="wait for $description (pid $pid)"
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.2
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    elapsed=$((elapsed + 1))
  done
  wait "$pid"
}
