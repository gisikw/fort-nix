---
id: fn-4dca
status: closed
deps: []
created: 2026-03-28T13:49:11Z
type: task
priority: 2
---
# Update doofenshmirtz to use barely-game-console overlay instead of pinned derivation

Steps:
1. Add overlay subscription to doofenshmirtz manifest: overlays.barely-game-console = { package = "dev/barely-game-console"; }
2. Update media-kiosk aspect to use /run/overlays/bin/barely-game-console instead of the pinned store path
3. Delete pkgs/barely-game-console/ (no longer needed)

Context: barely-game-console now has its own flake.nix + overlay.nix + CI pipeline. Binary is built by Forgejo CI, cached in Attic, and registered with the overlay-registry. The pinned derivation in fort-nix is obsolete.
