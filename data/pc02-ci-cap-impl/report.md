# PC02 Self-Hosted Runner Concurrency Cap - Investigation Report

## Finding: Already satisfied, no changes needed.

### What was searched

- **Workflow files** (`.github/workflows/*.yml`): All CI jobs use GitHub-hosted runners (`ubuntu-latest`, `windows-latest`, `macos-latest`). No job uses `runs-on: [self-hosted, ...]` or references the PC02 runner.
- **`LOCAL_TESTING.md`**: Documents a single self-hosted runner trial. The runner `seansminipc` (labels: `self-hosted, linux, x64, seansminipc`) was registered for this repo but never activated in any workflow file.
- **`CONTRIBUTING.md`**: Explicitly states "All CI jobs run on GitHub-hosted runners; `LOCAL_TESTING.md` owns the self-hosted-runner trial notes."
- **`data/learnings.md`**: PC02 section describes the LLM inference server, not a CI runner.
- **No projects clones exist** (`projects/` directory absent), so no external repos (e.g., `pc02-llm-lab-tooling`) could be inspected for separate runner configs.
- **No `concurrency:` groups** targeting a PC02 runner label exist in any workflow file.

### Why the captain's ruling is already in effect

1. **Only one runner instance was ever registered** (`seansminipc`). GitHub Actions defaults to running at most one job per runner instance. A single runner cannot execute two jobs concurrently.
2. **No self-hosted runner is currently in use.** All CI jobs target GitHub-hosted runners exclusively. The self-hosted runner was trialed, found to have issues (minimal PATH, state reuse, no sudo), and abandoned in favor of hosted runners.
3. **No concurrency configuration to modify.** There is no `concurrency:` group, no multi-runner label setup, and no workflow job targeting `[self-hosted, linux]` that would need a concurrency cap.

### Conclusion

The PC02 self-hosted runner concurrency cap of 1 is inherently satisfied by:
- Zero self-hosted jobs in any workflow file, and
- The single-runner registration (which GitHub limits to one concurrent job by default).

No code changes, configuration edits, or workflow modifications are needed.
