// Write-guard for PC02/opencode crewmate sessions: refuses any edit or write
// tool call that would escape this task's assigned worktree or its own
// report directory. Reproduced twice
// in production (2026-09-03
// token-burn-item10-no-self-resume, 2026-09-06 fm-relaunch-rebinds-pr-poll)
// when a tool call resolved a path against the primary checkout instead of
// $WT; both times the primary checkout's stray copy was only caught by
// accident via git status. tool.execute.before can block by throwing
// (verified against fm-primary-pretool-check.js, 2026-07-09 against OpenCode
// 1.17.15).
import { realpathSync } from "node:fs";
import { resolve, dirname, basename } from "node:path";

const realRoot = (p) => {
  try {
    return realpathSync(p);
  } catch {
    return resolve(p);
  }
};
const WORKTREE_ROOT = realRoot("/tmp/fm-guard-evidence.z2TCGj/demo/wt");
// The crewmate brief mandates exactly one write outside the worktree: the
// task's own report under $DATA/$ID (bin/fm-brief.sh Definition of done).
const TASK_DATA_ROOT = realRoot("/tmp/fm-guard-evidence.z2TCGj/demo/home/data/demo");
const ALLOWED_ROOTS = [WORKTREE_ROOT, TASK_DATA_ROOT];

function canonicalize(target) {
  const abs = resolve(target);
  const trailing = [];
  let probe = abs;
  for (;;) {
    try {
      return resolve(realpathSync(probe), ...trailing);
    } catch {
      const parent = dirname(probe);
      if (parent === probe) return abs;
      trailing.unshift(basename(probe));
      probe = parent;
    }
  }
}

function allowedTarget(target) {
  const real = canonicalize(target);
  return ALLOWED_ROOTS.some((root) => real === root || real.startsWith(root + "/"));
}

export const FmWorktreeGuard = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      const tool = input?.tool;
      const args = output?.args || {};
      if (tool === "write" || tool === "edit") {
        const target = args.filePath;
        if (typeof target === "string" && target && !allowedTarget(target)) {
          throw new Error(
            "fm-worktree-guard: refused " + tool + " outside the assigned worktree (" +
              WORKTREE_ROOT + "): " + target
          );
        }
      }
    },
  };
};
