# Why the new guard entries cannot be exercised inside this gate run

The gate reads `review.path_instructions` from the **trusted default-branch copy** of
`.no-mistakes.yaml`, not from the branch under review (same trust rule as
`disable_project_settings` and `commands.test`, documented in docs/configuration.md:742 and
docs/architecture.md:324). Evidence captured from this very run:

## 1. The trusted config the Review step used has only the three default-branch pointer rules

`no-mistakes eval capture` (local, no daemon) recorded the trusted config for review round 4,
whose reviewed head is 301ded94 (this branch, with all 7 guard entries):

```
captured case manifest (subset):
  "base_sha": "8b6945266c26f8963726d0bbfd838383393a264a",
  "head_sha": "301ded9420654d0022d57f3441baccb64184250c",
  "trusted_config_sha": "8b6945266c26f8963726d0bbfd838383393a264a",
  "no_mistakes_version": "v1.106.1",
```

`review.path_instructions` entries in that trusted config:

```
- path: bin/*.sh
- path: tests/*.test.sh
- path: AGENTS.md
```

## 2. Review log lines for every round of this run

```
3 trusted review instruction rule(s) matched no changed path: bin/*.sh, tests/*.test.sh, AGENTS.md
3 trusted review instruction rule(s) matched no changed path: bin/*.sh, tests/*.test.sh, AGENTS.md
3 trusted review instruction rule(s) matched no changed path: bin/*.sh, tests/*.test.sh, AGENTS.md
3 trusted review instruction rule(s) matched no changed path: bin/*.sh, tests/*.test.sh, AGENTS.md
```

There is no `applied N trusted review instruction block(s)` line in any round: none of the
trusted rules matched the diff, and the branch-local guard entries were not loaded at all.
That is decisive because round 4 changed exactly `.no-mistakes.yaml` and `docs/configuration.md`
(see `original/changed-files.json` of the captured case above), so the branch config's
`.no-mistakes.yaml` guard entry would have matched and been reported as applied had branch
review config been honored. So the guard text reaches reviewers only after this file lands on the default
branch.

## 3. Round provenance

```
step      round  reviewed_head                             trusted_config_sha
intent    1      None  None
rebase    1      None  None
review    1      b67f28230578b78772b373098ea26f78bfdf787c  8b6945266c26f8963726d0bbfd838383393a264a
review    2      1515b88b5fef52e67d48540b12150c4f007ec300  8b6945266c26f8963726d0bbfd838383393a264a
review    3      3cb1a9a58530706adb02bdf83f53e92b9397ecd1  8b6945266c26f8963726d0bbfd838383393a264a
review    4      301ded9420654d0022d57f3441baccb64184250c  8b6945266c26f8963726d0bbfd838383393a264a
```

## 4. The delivery mechanism itself is already proven in production

The engine applies these blocks per changed path today for the existing pointer rules
(43 historical review log lines in ~/.no-mistakes/logs); the first five:

```
applied 2 trusted review instruction block(s) for changed paths: bin/*.sh (2 file(s)); tests/*.test.sh (2 file(s))
applied 1 trusted review instruction block(s) for changed paths: tests/*.test.sh (1 file(s))
applied 1 trusted review instruction block(s) for changed paths: bin/*.sh (1 file(s))
applied 2 trusted review instruction block(s) for changed paths: bin/*.sh (2 file(s)); tests/*.test.sh (1 file(s))
applied 2 trusted review instruction block(s) for changed paths: bin/*.sh (1 file(s)); tests/*.test.sh (1 file(s))
```

So the missing in-run observation is activation timing, not the mechanism.
