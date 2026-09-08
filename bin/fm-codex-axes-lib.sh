#!/usr/bin/env bash
# fm-codex-axes-lib.sh - the ONE owner of which model/effort values a codex
# launch actually receives.
#
# Codex CLI silently launches on its own bundled default model and reasoning
# effort when neither flag is passed, which is the confirmed root cause of the
# 2026-09-05 burn incident. Two callers have to ask the same question about a
# codex launch and must never drift apart: bin/fm-spawn.sh, which composes the
# launch flags and refuses a spawn whose axes reach no flag, and
# bin/fm-control.sh, which mirrors that refusal on the PRE-STOP side of its
# relaunch transaction so a doomed launch never costs a running agent. Stating
# codex's accepted effort tiers here keeps that single owner.
#
# The installed codex config schema uses model_reasoning_effort, and the
# bundled model catalog advertises low|medium|high|xhigh. max is deliberately
# absent: codex does not advertise it, so it reaches no flag at all.

codex_effort_supported() {
  case "${1:-}" in
    low|medium|high|xhigh) return 0 ;;
  esac
  return 1
}

# A codex launch is fully resolved only when BOTH axes name something codex
# receives. An empty or literal-"default" model is the unresolved spelling both
# callers produce.
codex_axes_resolved() {
  local model=${1:-} effort=${2:-}
  [ -n "$model" ] && [ "$model" != default ] || return 1
  codex_effort_supported "$effort"
}
