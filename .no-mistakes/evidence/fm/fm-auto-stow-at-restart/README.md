# Live validation: restart-band auto-stow wake (fm/fm-auto-stow-at-restart)

Change under validation: `bin/fm-claude-stop-autoarm.sh` gains the restart-band auto-stow
wake (once per session, `state/.auto-stow-<session-id>` marker) plus docs and
`tests/fm-claude-stop-autostow.test.sh`.

## Evidence artifacts in this directory

| File | What it shows |
| --- | --- |
| `live-autostow-drive.log` | Full transcript of a disposable lab run: real Claude Code CLI (`claude 2.1.317`, machine login) driven with the run worktree's real Stop hook registered in a throwaway primary home (`$H/bin` symlinked to the run worktree's `bin`, marked lab home removed at the end). Covers the restart-band wake, once-per-session silence, a fresh session (post-`/clear`) wake, warn-band silence, AFK silence, `config/auto-stow-off` silence, and the captain's 250k/375k thresholds read by `bin/fm-context-usage.sh`. |
| `fm-claude-stop-autostow.test.log` | The shipped behavior suite `tests/fm-claude-stop-autostow.test.sh` run through `bin/fm-test-run.sh` (pass): bands, once-per-session marker, new-session wake, helper failure silence, off switch, secondmate opt-in, AFK, arm-first when supervision is uncovered, covered-watcher wake leaving the watcher alone, parallel single-wake race, and the long-poll guard-grace interplay with `bin/fm-turnend-guard.sh`. |
| `supervision-host-suite-load-run.log` + `supervision-host-isolated-reruns.log` | Re-run of `tests/fm-supervision-host.test.sh` (a suite selected by `--changed` because it runs the real Stop hook): the earlier run failed at the attended-latch probe assertion under host load; these re-runs are the disambiguation. |

## Key captured results (from `live-autostow-drive.log`)

* Restart-band turn in a real Claude session delivered the wake into the live session and
  created exactly one marker keyed to the real Claude session id:
  `stop hook feedback: firstmate auto-stow - this primary session reached the restart context band
  (context_tokens=25243, restart_tokens=1000). Run the stow skill now (/stow) ... then recommend
  /clear to the captain. Never run /clear yourself.`
* The same session's next stop added no second wake (wake entries before=2 after=2, markers stay 1).
* A fresh session (what the captain's `/clear` starts) produced its own single wake and its own
  marker.
* Warn band, AFK, and `config/auto-stow-off` each stayed silent with no marker.
* With the captain's real threshold values (`warn=250000`, `restart=375000` = 50% / 75% of the
  500k autoCompactWindow): 249999 -> ok, 250000 -> warn, 374999 -> warn, 375000 -> restart, and
  the Stop hook exited 2 with the auto-stow banner at exactly 375000 while staying silent at 374999.

## Re-drive after the review fixes (HEAD 5752f8ba, 2026-11-04)

| File | What it shows |
| --- | --- |
| `configured-test-rerun.log` | The configured command `bin/fm-test-run.sh --changed --exclude-family real-herdr-gated --pc02-if-idle` re-run exactly as-is, routed to PC02 slot 2 (`PC02 idle and ready; running tests remotely on pc02`): `FM_TEST_SUMMARY total=12 failed=0 skipped_gate=3 duration_ms=683217`. The three gate skips are the live-harness opt-in scripts. This clears the earlier load-induced `tests/fm-supervision-host.test.sh` flake; that suite passed here after 552s (`exit=0`). |
| `live-autostow-rerun.log` | A fresh disposable lab home (`/var/tmp/.../fm-lab.*`, removed at the end) running the real installed Claude Code CLI (`claude 2.1.318`, machine login) with the run worktree's tracked Stop registration: restart-band wake + marker, same-session resume silent, fresh session wake + second marker, warn band silent, `config/auto-stow-off` silent, and AFK silent. |
| `live-autostow-capture.log` + `claude-autostow-session.jsonl` | The real Claude transcript record of the delivered wake (`Stop hook feedback: ... firstmate auto-stow - this primary session reached the restart context band (context_tokens=27782, restart_tokens=1000) ... Run the stow skill now (/stow) ... Never run /clear yourself. This notice fires once per session.`) and the `stop_hook_summary` record of the asyncRewake hook. The transcript is the durable output of the real session. |
| `live-autostow-boundary.log` + `live-autostow-boundary.sh` | The captain's exact thresholds (`warn=250000 restart=375000`): helper band `warn` at 374999 and `restart` at 375000; real Stop hook exits 0 with no marker at 374999, exits 2 with the auto-stow banner and a marker at 375000, and stays silent on the same session's next Stop. |
| `fm-claude-stop-autostow-standalone.log` | The shipped behavior suite run alone through `bin/fm-test-run.sh`: `exit=0`. It drives the mechanical gates end-to-end (bands, once-per-session marker, helper failures, off switch, secondmate opt-in, AFK, arm-first when supervision is uncovered, covered-watcher wake, parallel single wake, and the long-poll guard-grace interplay). |

### Key captured results (re-drive)

* 374999 tokens: `band=warn`, hook `rc=0`, no marker. 375000 tokens: `band=restart`, hook `rc=2`, marker written, banner names the token counts; the same session's next Stop is `rc=0`.
* Real Claude session at the restart band received the wake and the model responded to it (recommended `/stow` and `/clear`, declined to run `/clear` itself); exactly one `state/.auto-stow-<session-id>` marker appeared.
* The same session resumed with `claude --continue` stayed silent and added no second marker; a fresh session (what a `/clear` starts) got its own single wake and marker.
* Warn band, `config/auto-stow-off`, and `state/.afk` produced no wake and no new marker.

## Uncovered-supervision fixture note

A separate real-Claude fixture with `state/task-1.meta` (supervision needed) and no live watcher
produced **no** auto-stow marker and no stow wake, which is the guard the change claims. The arm
itself could not complete in that pipe-launched fixture (`fm-primary-watchdog: refusing to arm:
cannot identify the primary's own pane`), so the arm-first completion is evidenced by
`tests/fm-claude-stop-autostow.test.sh` cases 9, 10 and 12 rather than by that fixture.
