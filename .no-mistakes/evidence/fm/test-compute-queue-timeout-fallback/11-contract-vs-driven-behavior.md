# Documented exit-code and fallback contract vs. what was driven live

Public contract as emitted by the product's own `--help` (generated from the
script header) and by docs/configuration.md, with the scenario that exercised
each clause against the real `bin/fm-test-compute.sh`.

## --help (excerpt, run from the run worktree)

```
$ bin/fm-test-compute.sh --help   # excerpt
Result receipts bind every hosted partition to HEAD and the exact selected
scripts. A test/lint failure is terminal, never grounds for a greener local
rerun. Hosted faults fail closed with exit 77 so a gate can tell
infrastructure from a test or lint verdict. Unavailable tiers fall through to
local admission instead: GitHub workflow state, startup failure, or dispatch
rejection; a GitHub ambiguous POST whose run never appears within the queue
bound (treated as not started, so it may race a later tier); GitLab
authentication, project reads, dispatch rejection, quota rejection, or
missing receipts; and a cancellation confirmed after a queue timeout or a
GitLab execution timeout. An accepted GitHub dispatch that stays
undiscovered fails closed rather than being duplicated.
...
Exit: 0 proven success; 1 failed hosted evidence or a failed hosted receipt;
2 usage error; 77 hosted outcome indeterminate (an infrastructure fault, or
a dispatched run that may still be executing, never a test or lint verdict).
```

## docs/configuration.md (lines 775-781)

- "A failing test or lint receipt fails the caller and never triggers a second run on another tier."
  -> driven: 07-real-lint-failure-still-exit1 (exit 1, `Hosted partition failed: lint-1`, no local run, no GitLab).
- "Indeterminate infrastructure and monitoring faults fail closed with exit 77 ... receipt evidence that cannot prove the exact head and scripts still exits 1."
  -> driven exit 77: 03, 03b, 04, 05, 06. Receipt-integrity exit 1 is covered by the focused suite (`wrong-head`, `wrong-scripts` cases).
- "Unavailable tiers fall through to PC02/PC01 admission ... GitHub workflow state ... a GitHub ambiguous dispatch whose run never appears within the queue bound ... GitLab authentication ... and a cancellation confirmed after a queue timeout".
  -> driven fallback: 01 (confirmed queue-timeout cancellation -> local lint admission), 02 (ambiguous dispatch -> local lint admission), 09 (GitHub unavailable -> GitLab success).
- "An accepted GitHub dispatch that stays undiscovered fails closed rather than duplicating the suite on another tier."
  -> driven: 03 (lint) and 03b (test) both exit 77 with no GitLab contact and no local admission.
- "An ambiguous GitLab pipeline dispatch fails closed with exit 77 ..."
  -> focused suite: `gitlab-pipeline-ambiguous`. Driven exit-77 GitLab monitoring/artifact faults: 05, 06.
- "A queued run can fall back only after its cancellation is confirmed."
  -> driven: 01 shows the cancellation followed by confirmed `completed/cancelled` before the 75 fall-through; the focused suite pins the unconfirmed case (`cancel-failure` -> 77).

## Conclusion

Every documented clause that a gate depends on was observed on the real router:
the two reported incidents now fall back, infrastructure faults are 77, and
genuine lint failures remain exit 1.
