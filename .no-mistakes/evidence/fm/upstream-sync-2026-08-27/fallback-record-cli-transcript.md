# Degraded secondmate rows — `fm-fleet-snapshot.sh --json` (the record interface /bearings consumes)

Fixture: one registered *remote* secondmate `ios` in `data/secondmates.md` whose home summary comes back unusable over a stubbed `ssh`.
Both cases must degrade to a single unavailable row, never take the whole fleet snapshot down.

## A. Home summary exceeds FM_SNAPSHOT_SECONDMATE_MAX_BYTES (300 KiB valid-JSON blob)

### Before the fix (a75b784) — argv ceiling, whole snapshot fails
```
$ fm-fleet-snapshot.sh --json   # exit 1
/home/sean_/.no-mistakes/worktrees/4936102b4bcf/01M119KG0Q4Q3TMXRQ5D6V56ZT/bin/fm-fleet-snapshot.sh: line 1565: /home/sean_/.local/bin/jq: Argument list too long
fm-fleet-snapshot: registered secondmate aggregation failed
```

### After the fix (baf8df9) — degraded row, exit 0
```
$ fm-fleet-snapshot.sh --json   # exit 0
{
  "id": "ios",
  "home": "/opt/fm-home",
  "host": "ios-host",
  "remote": true,
  "registered": true,
  "spawn_gen": null,
  "current": {
    "state": "unknown",
    "reason": "structured home snapshot exceeded byte limit"
  },
  "invalidity": null,
  "reconcile_inventory": null,
  "provenance": {
    "selected": "unknown",
    "structured_home": "/opt/fm-home",
    "parent_event_role": "fallback-only-not-current"
  },
  "freshness": {
    "status": "unknown",
    "observed_at": "2026-08-27T09:53:43Z",
    "age_seconds": null
  },
  "active_children": [],
  "decisions_open": [],
  "holds": [],
  "queued": [],
  "landed": [],
  "endpoints": [],
  "counts": {
    "active_children": 0,
    "decisions_open": 0,
    "holds": 0,
    "queued": 0,
    "landed": 0,
    "endpoints": 0
  },
  "omitted": [],
  "parent_event": {
    "raw": "",
    "note": "",
    "age_seconds": null,
    "open_activities": [],
    "open_decisions": [],
    "activity_scan": {
      "records": [],
      "available": true,
      "input_truncated": false,
      "retained_truncated": false,
      "reasons": [],
      "lines_in_window": 0,
      "records_in_window": 0
    }
  },
  "terminal_evidence": {
    "provenance": "parent-direct-report-terminal",
    "trust": "untrusted-supplement",
    "captured": false,
    "observed_at": "2026-08-27T09:53:43Z",
    "freshness": "not-collected",
    "reason": "no parent event to compare",
    "lines": 0,
    "bytes": 0,
    "event_note_seen": false,
    "contradiction": false
  },
  "contradiction": false
}
```

## B. Home summary is not JSON at all (ssh banner text)

### Before the fix (a75b784) — `--argjson` rejects it, whole snapshot fails
```
$ fm-fleet-snapshot.sh --json   # exit 1
jq: invalid JSON text passed to --argjson
Use jq --help for help with command-line options,
or see the jq manpage, or online docs at https://jqlang.org
```

### After the fix (baf8df9) — degraded row, exit 0
```
$ fm-fleet-snapshot.sh --json   # exit 0
{
  "id": "ios",
  "home": "/opt/fm-home",
  "host": "ios-host",
  "remote": true,
  "registered": true,
  "spawn_gen": null,
  "current": {
    "state": "unknown",
    "reason": "structured home snapshot was malformed or stale"
  },
  "invalidity": null,
  "reconcile_inventory": null,
  "provenance": {
    "selected": "unknown",
    "structured_home": "/opt/fm-home",
    "parent_event_role": "fallback-only-not-current"
  },
  "freshness": {
    "status": "unknown",
    "observed_at": "2026-08-27T09:53:44Z",
    "age_seconds": null
  },
  "active_children": [],
  "decisions_open": [],
  "holds": [],
  "queued": [],
  "landed": [],
  "endpoints": [],
  "counts": {
    "active_children": 0,
    "decisions_open": 0,
    "holds": 0,
    "queued": 0,
    "landed": 0,
    "endpoints": 0
  },
  "omitted": [],
  "parent_event": {
    "raw": "",
    "note": "",
    "age_seconds": null,
    "open_activities": [],
    "open_decisions": [],
    "activity_scan": {
      "records": [],
      "available": true,
      "input_truncated": false,
      "retained_truncated": false,
      "reasons": [],
      "lines_in_window": 0,
      "records_in_window": 0
    }
  },
  "terminal_evidence": {
    "provenance": "parent-direct-report-terminal",
    "trust": "untrusted-supplement",
    "captured": false,
    "observed_at": "2026-08-27T09:53:44Z",
    "freshness": "not-collected",
    "reason": "no parent event to compare",
    "lines": 0,
    "bytes": 0,
    "event_note_seen": false,
    "contradiction": false
  },
  "contradiction": false
}
```
