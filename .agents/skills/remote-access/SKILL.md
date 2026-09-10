---
name: remote-access
description: >-
  Remote access reference for reaching PC01 (this firstmate home) from away:
  SSH from an Android phone over Tailscale, attaching the firstmate tmux session,
  and the self-hosted Herdr mobile monitor/approve relay.
  Use when the captain asks how to reach PC01 remotely, SSH in from their phone,
  attach or detach the tmux session, or re-pair the Herdr mobile app.
user-invocable: false
metadata:
  internal: true
---

# Remote access reference

Load when the captain needs remote access to PC01 (this firstmate home).

## SSH from Android (Termux)
`ssh sean_@100.93.55.109` (Tailscale address)

## tmux session
After SSH: `wsl -d Ubuntu -- tmux attach -t firstmate -r` (read-only; drop `-r` to type)
- `Ctrl-b w` picks window
- `Ctrl-b d` detaches

## Herdr mobile relay (self-hosted 2026-09-10)
Live phone-native monitor/approve app, paired and working.
PWA self-hosted at Cloudflare Pages `herdr-0cv-2wd.pages.dev` (account: sean.morden1993@gmail.com).
Connection via community WebRTC gateway, no cloudflared/tunnel account needed.
Reprint a pairing QR any time from the `herdr-mobile-relay.events` plugin's setup menu (option 7).
