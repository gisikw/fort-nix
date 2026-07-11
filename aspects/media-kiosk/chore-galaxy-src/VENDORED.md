# Vendored: chore-galaxy

Source of truth: `~/Projects/chore-galaxy` (Kevin's dev sandbox), commit
`5afb9ec00ce56187a4c0ebcfd7b52577ce6525c5` (main, 2026-07-11).

Vendored here because the sandbox that shipped the TV cutover could not
create/push `infra/chore-galaxy` on the forge (permission boundary). Once
that repo exists and CI publishes to the overlay registry, the intended
shape is the fort-overlay-manager pipeline (the source repo already carries
a deploy-ready `overlay.nix` and `.forgejo/workflows/deploy.yml`); this
directory and the `galaxy.package` build in `../default.nix` then become an
`overlays.chore-galaxy` declaration in the doofenshmirtz manifest.

To refresh until then: `git -C ~/Projects/chore-galaxy archive main -- go.mod
'*.go' web state.example.json | tar -x -C <this dir>` and update the sha above.
