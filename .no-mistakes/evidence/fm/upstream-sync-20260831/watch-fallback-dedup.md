# Watcher wake-queue: the commit-error fallback enqueues one record per wake

Durable queue file ($FM_HOME/state/.wake-queue) after the benign absorb branch's
status-commit-error fallback fires. Columns: epoch, seq, kind, key, reason.
`othersrc.status` is the uncommittable status file; `delivery-src.status` is the
signal deferred behind an unacknowledged process-event generation.

## BEFORE (bin/fm-watch.sh at 85ea153^): two signal records for one wake
```
  not ok - the commit-error fallback enqueued 2 records for 1 wakes: 1788348849	1	check	procevent:delivery-src:1	check: procevent lavish delivery-src 1
  1788348852	4	signal	othersrc.status	signal: /tmp/fm-wake-pair-dedup-tests.v7dgsv/procevent-defer-commit-error/state/othersrc.status
  1788348852	5	signal	othersrc.status	signal: /tmp/fm-wake-pair-dedup-tests.v7dgsv/procevent-defer-commit-error/state/othersrc.status
```

## AFTER (bin/fm-watch.sh at 85ea153): one record, and the deferred signal stays deferred
```
  ok - one event enqueues once: its status signal never becomes a second wake
  ok - a routine status line keeps its signal wake rather than being silently absorbed
  ok - a routine line beside a still-open decision keeps its own signal wake
  ok - a status change written after the check wake, in the same second, is never coalesced
  ok - a signal deferred behind an unacknowledged generation is delayed, never dropped
  ok - a deferred signal keeps its marker when a benign signal shares the cycle
  ok - the benign branch's commit-error fallback leaves a deferred signal deferred and enqueues once
  ok - a status signal with no process-event coverage wakes normally
  
  All wake-pair-dedup tests passed.
```
