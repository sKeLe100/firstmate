# Guard-the-bar review instructions: what the Review step resolves for a diff

Generated from the committed `.no-mistakes.yaml` by `verify_guard_globs.py`, using the gate's
documented glob matcher (Go `path.Match`, where `*` never crosses `/`).
Each block below is the exact instruction text the Review step attaches to the matching changed paths.

## A bar-lowering change to a recorded review capture (nested test asset)

Changed paths: `tests/captures/no-mistakes-v1.70.1/completed.toon`

**Injected for `tests/*/*/*`** (matched: `tests/captures/no-mistakes-v1.70.1/completed.toon`)

```text
Flag each diff that lowers the bar, citing its concrete line: a deleted, skipped, or quarantined test; a removed or weakened assertion; a new lint or shellcheck suppression; a stub or short-circuit that makes a check pass; a raised timeout, retry count, or tolerance; a narrowed test selection. Accept it only when the PR description states why.
```

## A stub-based renderer change and a weakened fixture

Changed paths: `tests/assets/board-render-harness.mjs`, `tests/fixtures/opencode-1.18.31-cwd/opencode-1.18.31-idle-cwd.ansi`

**Injected for `tests/*/*`** (matched: `tests/assets/board-render-harness.mjs`)

```text
Flag each diff that lowers the bar, citing its concrete line: a deleted, skipped, or quarantined test; a removed or weakened assertion; a new lint or shellcheck suppression; a stub or short-circuit that makes a check pass; a raised timeout, retry count, or tolerance; a narrowed test selection. Accept it only when the PR description states why.
```

**Injected for `tests/*/*/*`** (matched: `tests/fixtures/opencode-1.18.31-cwd/opencode-1.18.31-idle-cwd.ansi`)

```text
Flag each diff that lowers the bar, citing its concrete line: a deleted, skipped, or quarantined test; a removed or weakened assertion; a new lint or shellcheck suppression; a stub or short-circuit that makes a check pass; a raised timeout, retry count, or tolerance; a narrowed test selection. Accept it only when the PR description states why.
```

## A backend script whose check the author loosens

Changed paths: `bin/backends/herdr.sh`

**Injected for `bin/backends/*`** (matched: `bin/backends/herdr.sh`)

```text
Flag each diff that lowers the bar, citing its concrete line: a deleted, skipped, or quarantined test; a removed or weakened assertion; a new lint or shellcheck suppression; a stub or short-circuit that makes a check pass; a raised timeout, retry count, or tolerance; a narrowed test selection. Accept it only when the PR description states why.
```

## A CI workflow that stops running the suite, plus the gate config that would let it through

Changed paths: `.github/workflows/ci.yml`, `.no-mistakes.yaml`

**Injected for `.github/workflows/*`** (matched: `.github/workflows/ci.yml`)

```text
Flag each diff that lowers the bar, citing its concrete line: a deleted, skipped, or quarantined test; a removed or weakened assertion; a new lint or shellcheck suppression; a stub or short-circuit that makes a check pass; a raised timeout, retry count, or tolerance; a narrowed test selection. Accept it only when the PR description states why.
```

**Injected for `.no-mistakes.yaml`** (matched: `.no-mistakes.yaml`)

```text
Flag each diff that lowers the bar, citing its concrete line: a deleted, skipped, or quarantined test; a removed or weakened assertion; a new lint or shellcheck suppression; a stub or short-circuit that makes a check pass; a raised timeout, retry count, or tolerance; a narrowed test selection, including weakening these bar-lowering guard rules themselves. Accept it only when the PR description states why.
```

## Documentation-only diff (control: no bar-lowering instruction should be injected)

Changed paths: `docs/configuration.md`

_No `review.path_instructions` block applies to this diff._

