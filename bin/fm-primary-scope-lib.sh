#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home.
# This file is sourced by hook entrypoints and has no side effects on source.

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
#
# $1/$2 (root/state) are typically derived from FM_ROOT_OVERRIDE/FM_HOME, which
# a crewmate task worktree can inherit unchanged from the ambient environment
# it was launched in (e.g. the real primary home's own env), even though the
# guarded process is actually a checkout of the firstmate repo itself running
# from an isolated task worktree. Trusting root/state alone would then
# misclassify that worktree as PRIMARY. Guard against that by requiring the
# actual on-disk location this code is running from (this library's own
# sourced path, never the possibly-overridden root) to match root's own
# git-dir: every worktree/clone of firstmate has its own physical bin/, so a
# leaked-env task worktree's real location never coincides with the
# overridden primary root's git-dir even though root itself still resolves
# to a genuine primary checkout.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir actual_dir actual_git_dir root_git_dir
  actual_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P) || return 1
  actual_git_dir=$(git -C "$actual_dir" rev-parse --git-dir 2>/dev/null) || return 1
  case "$actual_git_dir" in
    /*) : ;;
    *) actual_git_dir=$(cd "$actual_dir/$actual_git_dir" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  root_git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
  case "$root_git_dir" in
    /*) : ;;
    *) root_git_dir=$(cd "$root/$root_git_dir" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  [ "$actual_git_dir" = "$root_git_dir" ] || return 1
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}
