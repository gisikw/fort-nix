---
id: fn-f20f
status: in_progress
deps: []
created: 2026-03-28T17:01:41Z
type: task
priority: 2
---
# Route barely-game-console stderr to journal via systemd-cat in media-kiosk launcher

barely-game-console now has lifecycle logging (startup, RFID scans, child spawn/exit with duration, power button kills) but eprintln output doesn't reach journal because greetd/cage don't forward children's stderr.

Fix: in the game-console launcher wrapper (aspects/media-kiosk/default.nix), change:
  exec /run/overlays/bin/barely-game-console
to:
  exec systemd-cat -t barely-game-console /run/overlays/bin/barely-game-console

Then logs are visible via: journalctl -t barely-game-console
Or remotely: fort doofenshmirtz journal '{"unit":"barely-game-console"}'
