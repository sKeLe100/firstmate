#!/usr/bin/env bash
# fm-pc02-run-root-lib.sh - the PC02 offload run-root naming contract, one owner.
#
# bin/fm-pc02-test-offload.sh creates each PC02 run root, and
# bin/fm-test-run-stop.sh finds a run's roots. Both source this file, so the
# two cannot disagree about the name. Sourcing it runs nothing and contacts
# nothing.
#
# A run root is "<base>/run-<cksum>-<pid>", where <cksum> is the POSIX cksum of
# the local run root path. fm_pc02_remote_run_prefix prints the part before the
# pid, "<base>/run-<cksum>-".
#
# Env overrides:
#   FM_PC02_OFFLOAD_REMOTE_BASE   PC02 run-root base under $HOME
#                                 (default: .fm-pc02-test-offload)

# The offload script's file name, so callers can name the script without
# repeating the literal.
# shellcheck disable=SC2034 # Read by the files that source this library.
FM_PC02_OFFLOAD_SCRIPT=fm-pc02-test-offload.sh

# Prints the PC02 run-root prefix for local run root $1.
fm_pc02_remote_run_prefix() {  # <local-run-root>
  printf '%s/run-%s-\n' \
    "${FM_PC02_OFFLOAD_REMOTE_BASE:-.fm-pc02-test-offload}" \
    "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}
