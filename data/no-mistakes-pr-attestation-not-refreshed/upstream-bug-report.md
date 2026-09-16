---
title: "PR attestation rebind silently no-ops when gh pr edit fails (gh 2.46.0 projectCards GraphQL error)"
labels: ["bug", "attestation"]
---

## Symptom

The no-mistakes pipeline's PR-body attestation comment (`no-mistakes-pipeline-attestation:v1`)
does not refresh on later pushes to an already-open PR. It stays stuck at the branch's
original `head_sha` even after later pipeline runs complete their "push" step against newer
heads. The required "PR must be raised via no-mistakes" GitHub check correctly fails
(permanent red) on any PR pushed more than once by no-mistakes, because the attestation
never gets rebound to the new head.

This has been confirmed on multiple PRs against the firstmate repo:
- PR #45, #39, and others (per firstmate backlog/learnings)
- Confirmed live 2026-09-16 on PR #125 (and #122)

## Root cause

The pipeline's rebind logic in `internal/pipeline/steps/ci_fix.go:restampPRAttestationWithSteps`
runs the correct underlying call (`gh pr edit` against the PR body), but on gh CLI version
**2.46.0**, that call fails with a `projectCards` GraphQL error that the CLI version doesn't
handle cleanly:

```
gh pr edit <pr-selector> --base <repo> --body-file -
# Returns exit 1 with:
# projectCards: Field 'projectCards' doesn't exist on type 'PullRequest' ...
```

Every rebind attempt therefore silently no-ops instead of visibly failing.

**The silence is the bug.** The rebind code (ci_fix.go:863-876) does log retry failures:

```go
if logfn != nil && attempt < attempts {
    logfn(fmt.Sprintf("attestation rebind attempt %d/%d failed: %v; retrying", attempt, attempts, err))
}
```

But this log message only appears in the no-mistakes daemon log, not in the pipeline's
visible output to the user/agent. The pipeline continues as if the rebind succeeded because
the error is not surfaced as a visible finding in the PR body or pipeline output. The agent
never sees the failure, never knows the attestation is stale, and the GitHub check fails
indefinitely.

## Repro

```bash
# 1. Run no-mistakes on a branch with an existing PR
no-mistakes axi run --intent "test"
# Pipeline creates PR with attestation bound to initial head_sha

# 2. Push a new commit to the same branch (rebase/fix)
git commit --allow-empty -m "new commit"
git push origin HEAD

# 3. Run no-mistakes again on the same branch
no-mistakes axi run --intent "test"
# The push step calls attestHeadBeforePush() → restampPRAttestationWithSteps()
# which calls gh pr edit to rebind the attestation to the new head

# 4. Observe: gh 2.46.0 returns exit 1 with projectCards GraphQL error
# The rebind log message appears only in daemon logs, not in pipeline output

# 5. Result: attestation stays bound to old head_sha, PR check permanently red
```

gh version info:
```
gh version 2.46.0 (2024-XX-XX)
```

The actual fix for the root cause (upgrading gh past 2.46.0, which needs GitHub's own apt
repo since the distro repo caps at 2.46.0-4) is a separate infra task. But the pipeline
should surface this failure loudly regardless of the gh version.

## Short-term mitigation for firstmate operators

Until the gh upgrade and/or an upstream fix lands, operators can manually rebind the
attestation to the correct head_sha:

```bash
# Find the correct head_sha from the latest pipeline run
no-mistakes runs --limit 5  # find the latest completed run's head

# Manually update the PR body with the correct attestation
# The attestation is an HTML comment in the PR body:
# <!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"...","steps":[...]} -->

# Option A: gh pr edit with correct body
HEAD_SHA=$(git rev-parse HEAD)
PR_URL="https://github.com/OWNER/REPO/pull/NNN"
# Read current body, find and replace the head_sha in the attestation comment
# (use sed or jq carefully to preserve the rest of the body)

# Option B: gh api PATCH (bypasses the projectCards field entirely)
curl -fSL \
  -X PATCH \
  -H "Authorization: token $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/OWNER/REPO/pulls/NNN" \
  -d "{\"body\": \"<new-body-content>\"}"

# Option C: If gh CLI is upgraded past 2.46.0, the native rebind works again
```

## Suggested fix

In `restampPRAttestationWithSteps` (ci_fix.go), the rebind failure should be surfaced
not just as a daemon log line but as a visible error that aborts the pipeline and appears
in the pipeline output/PR body. The current code wraps the error in
`errAttestationWriteFailed`, but that wrapped error is not actually propagating out of
`attestHeadBeforePush` as a failure the push step honors — confirmed runs complete
successfully with a stale attestation instead of aborting. The wrapping needs to actually
cause the push step to fail, and the error needs to be visible in the pipeline summary
(PR body) so the agent/captain sees it.

Additionally, the retry loop's log messages (ci_fix.go:872-874) should be emitted through
the step's `sctx.Log` which feeds into the visible pipeline log, not just the daemon log.
