#!/usr/bin/env bash
# fm-pc02-run-root-lib.sh - the PC02 offload run-root naming contract, one owner.
#
# bin/fm-pc02-test-offload.sh creates each PC02 run root, and
# bin/fm-test-run-stop.sh finds a run's roots. Both source this file, so the
# two cannot disagree about the name. Sourcing it runs nothing and contacts
# nothing.
#
# A run root is "<base>/run-<digest>-<pid>", where <digest> is the leading
# decimal digits of the POSIX cksum of the local run root path.
# fm_pc02_remote_run_prefix prints the part before the pid,
# "<base>/run-<digest>-".
#
# The name is deliberately short and dot-free. A run's TMPDIR lives inside the
# run root ("<root>/tmp"), and the suite nests per-script and per-family roots
# several levels below it. Linux caps an AF_UNIX socket path at 108 bytes
# including the trailing NUL, so a longer or dotted root makes tests that bind a
# socket or build a git ref from a temp path fail for reasons unrelated to the
# code under test:
#   - fm-herdr-groups binds
#     "<TMPDIR>/fm-test-run.*/w1/tmp/fm-herdr-groups.*/view-helper/s.sock",
#     which adds 68 fixed characters below TMPDIR;
#   - fm-brief embeds a marker path in a branch name, and git check-ref-format
#     rejects a path component that starts with a dot;
#   - fm-test-run records PATH entries truncated to 120 characters.
# With a typical 12-character home and a 7-digit pid the temp root is 38
# characters, so the socket path is 106 and keeps one byte of margin under the
# 107-byte limit; keep every component here short, and never start the base
# with a dot. Overrides are the operator's own responsibility to keep within
# the same budget.
#
# Env overrides:
#   FM_PC02_OFFLOAD_REMOTE_BASE   PC02 run-root base under $HOME
#                                 (default: fmp)

# The offload script's file name, so callers can name the script without
# repeating the literal.
# shellcheck disable=SC2034 # Read by the files that source this library.
FM_PC02_OFFLOAD_SCRIPT=fm-pc02-test-offload.sh

# shellcheck disable=SC2034 # Read by the files that source this library.
FM_PC02_OFFLOAD_REMOTE_BASE_DEFAULT=fmp
# The base earlier offloads used; roots left there are still reported and reclaimed.
# shellcheck disable=SC2034 # Read by the files that source this library.
FM_PC02_OFFLOAD_REMOTE_BASE_LEGACY=.fm-pc02-test-offload
# Five decimal digits of a 32-bit cksum; the pid still distinguishes concurrent
# runs, so this only narrows which stale roots a stop walks.
# shellcheck disable=SC2034 # Read by the files that source this library.
FM_PC02_RUN_DIGEST_CHARS=5

# Prints the PC02 run-root prefix for local run root $1.
fm_pc02_remote_run_prefix() {  # <local-run-root>
  printf '%s/run-%s-\n' \
    "${FM_PC02_OFFLOAD_REMOTE_BASE:-$FM_PC02_OFFLOAD_REMOTE_BASE_DEFAULT}" \
    "$(printf '%s' "$1" | cksum | cut -d' ' -f1 | cut -c1-"$FM_PC02_RUN_DIGEST_CHARS")"
}
