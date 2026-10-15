#!/usr/bin/env bash
# fm-test-env-record.sh - print a bounded, secret-free snapshot of the shell
# context that is about to execute the behavior suite.

clean_value() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | cut -c1-240
}

fm_test_env_record_main() {
  local tmp_fs=unknown tmpdir_path process_model subreaper chrome candidate chrome_tmp
  tmpdir_path=${TMPDIR:-/tmp}
  if command -v df >/dev/null 2>&1; then
    tmp_fs=$(df -PT "$tmpdir_path" 2>/dev/null | awk 'NR==2 {print $2}')
    if [ -z "$tmp_fs" ]; then
      tmp_fs=$(stat -f '%T' "$tmpdir_path" 2>/dev/null || true)
    fi
  fi
  [ -n "$tmp_fs" ] || tmp_fs=unknown

  printf 'FM_TEST_ENV_RECORD v=1\n'
  printf 'shell=bash version=%s flags=%s argv0=%s pid=%s ppid=%s\n' \
    "$(clean_value "${BASH_VERSION:-unknown}")" "${-:-}" \
    "$(basename -- "$0")" "$$" "$PPID"
  local runner_login=no parent_login=unknown parent_arg
  shopt -q login_shell 2>/dev/null && runner_login=yes
  if [ -r "/proc/$PPID/cmdline" ]; then
    parent_login=no
    local parent_idx=0
    while IFS= read -r -d '' parent_arg && [ "$parent_idx" -lt 3 ]; do
      case "$parent_idx:$parent_arg" in
        0:-* | *:--login | [12]:-*l*) parent_login=yes; break ;;
      esac
      parent_idx=$((parent_idx + 1))
    done < "/proc/$PPID/cmdline"
  fi
  printf 'runner_login_shell=%s parent_login_shell=%s\n' "$runner_login" "$parent_login"
  local path_entries=() path_entry
  IFS=: read -r -a path_entries <<<"${PATH:-}"
  printf 'path_entries='
  for path_entry in "${path_entries[@]:0:20}"; do
    printf '%s:' "$(clean_value "$path_entry" | cut -c1-120)"
  done
  printf '\n'
  printf 'shell_options='
  set -o | awk '$2 == "on" {printf "%s%s", sep, $1; sep=","} END {print ""}'
  printf 'os=%s kernel=%s machine=%s\n' "$(uname -s 2>/dev/null || echo unknown)" \
    "$(uname -r 2>/dev/null || echo unknown)" "$(uname -m 2>/dev/null || echo unknown)"
  if command -v ps >/dev/null 2>&1; then
    process_model=$(ps -o pid=,ppid=,pgid=,sid= -p "$$" 2>/dev/null | awk '{$1="pid=" $1; $2="ppid=" $2; $3="pgid=" $3; $4="sid=" $4; print}')
  else
    process_model="pid=$$ ppid=$PPID pgid=unknown sid=unknown"
  fi
  subreaper=unknown
  if [ -r "/proc/$$/status" ]; then
    subreaper=$(awk '/^ChildSubreaper:/ {print $2}' "/proc/$$/status")
    [ -n "$subreaper" ] || subreaper=not-exposed-by-procfs
  fi
  printf 'process_model=%s subreaper=%s\n' "${process_model:-unknown}" "$subreaper"
  printf 'tmpdir_fs=%s\n' "$(clean_value "$tmp_fs")"
  while IFS= read -r limit; do
    printf 'ulimit=%s\n' "$(clean_value "$limit")"
  done < <(ulimit -a 2>&1)

  fm_test_env_tool_record bash --version
  fm_test_env_tool_record node --version
  fm_test_env_tool_record pi --version
  fm_test_env_tool_record tasks-axi --version
  fm_test_env_tool_record timeout --version
  fm_test_env_tool_record git --version
  fm_test_env_tool_record herdr --version
  fm_test_env_tool_record tmux -V
  fm_test_env_tool_record rsync --version
  fm_test_env_tool_record no-mistakes --version

  chrome=
  for candidate in chromium chromium-browser google-chrome google-chrome-stable; do
    chrome=$(type -P "$candidate" 2>/dev/null || true)
    [ -z "$chrome" ] || break
  done
  if [ -z "$chrome" ]; then
    printf 'chrome_startup=missing\n'
  elif ! type -P timeout >/dev/null 2>&1; then
    printf 'chrome_startup=failed reason=timeout-missing path=%s\n' "$chrome"
  else
    chrome_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-chrome.XXXXXX" 2>/dev/null || true)
    if [ -z "$chrome_tmp" ]; then
      printf 'chrome_startup=failed reason=tempdir-unavailable path=%s\n' "$chrome"
    else
      if env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$chrome_tmp" TMPDIR="$chrome_tmp" \
        timeout 8 "$chrome" --headless --no-sandbox --disable-gpu \
        --disable-dev-shm-usage --disable-background-networking \
        --disable-component-update --disable-sync --disable-extensions \
        --no-first-run --no-default-browser-check \
        --user-data-dir="$chrome_tmp/profile" --dump-dom about:blank \
        >/dev/null 2>&1; then
        printf 'chrome_startup=ok path=%s\n' "$chrome"
      else
        printf 'chrome_startup=failed path=%s\n' "$chrome"
      fi
      rm -rf "$chrome_tmp"
    fi
  fi
  printf 'FM_TEST_ENV_RECORD_END\n'
}

fm_test_env_tool_record() {  # <tool> <version arguments...>
  local tool=$1 path version status=0 timeout_path
  shift
  path=$(type -P "$tool" 2>/dev/null || true)
  if [ -z "$path" ]; then
    printf 'tool=%s absent\n' "$tool"
    return 0
  fi
  timeout_path=$(type -P timeout 2>/dev/null || true)
  if [ -z "$timeout_path" ]; then
    version="unprobed-timeout-missing"
  else
    version=$("$timeout_path" 5 "$path" "$@" 2>&1 </dev/null) || status=$?
    version=${version%%$'\n'*}
    if [ "$status" -eq 124 ]; then
      version="timed-out"
    elif [ -z "$version" ]; then
      version="version-unavailable"
    fi
  fi
  printf 'tool=%s path=%s version=%s\n' "$tool" "$path" "$(clean_value "$version")"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_test_env_record_main
fi
