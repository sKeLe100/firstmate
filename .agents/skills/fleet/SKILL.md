---
name: fleet
description: >-
  Show every fleet resource and live worker when the captain invokes /fleet or asks what hosts, drives, quota lanes and accounts, workers, panes, secondmates, roles, testing environments, or connected compute accounts the fleet has.
user-invocable: true
metadata:
  internal: true
---

# fleet

Answer "what does the fleet have and what is every worker doing" from one deterministic, read-only snapshot.
This is a resource and worker inventory, not a resume digest: use `bearings` for where the captain left off.

## What it does

1. **Gather with one deterministic command.**
   Run `bin/fm-resource-snapshot.sh` at invocation time and read its TOON output.
   It is the single bounded, read-only source for hosts, drives, quota lanes, workers, Herdr panes and strays, secondmates, orchestrator/role assignment, testing environments, Android emulator availability, and connected compute accounts.
   Its header and `--help` output own the exact sections, fields, bounds, and fixture seams.
   Do not substitute a second fleet-state reader, a raw `/bearings` projection, or ad-hoc `gh`, `glab`, `ssh`, or `herdr` queries for what it already reports.

2. **Render the sections the captain asked for.**
   Lead with the host and drive state, then quota lanes with every window in the order given, then the worker table with machine, lane, task, model, stage, age, context band, and PR, then panes and strays, then secondmates and roles, then testing environments and Android emulator availability, then compute accounts.
   For Android, name each host's AVDs, serials, adb device state, and boot completion: a `stopped` AVD exists but is not running, `none` means the probes read cleanly and found no emulator, and a missing adb or emulator, or a recorded Android root or AVD home that is missing or unreadable, is stated with its reason rather than reported as zero devices.
   Name the orchestrator, the supervision host and engine, and each secondmate explicitly so "who is orchestrating" is answered without inference.
   A `stale` or `failed` figure says so with its reason and read time; never restate it as zero or as current.
   Convert `read_utc` times to US Eastern when speaking to the captain.

3. **Stay observational.**
   Never spawn, steer, merge, tear down, reorder, edit backlog, or change a project, host, account, or test slot from this skill.
   Recommend the next action only when the snapshot itself exposes a decision the captain needs, and leave acting on it to the normal lifecycle.
