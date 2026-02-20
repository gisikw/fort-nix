---
id: fort-beu
status: open
deps: []
links: []
created: 2026-01-01T19:51:45.940347811Z
type: task
priority: 4
---
# Set up home-config repo in dev-sandbox and Forgejo

Mirror the home-config (home-manager) repo into Forgejo and make it accessible from dev-sandbox, similar to fort-nix.

Backburner. Kevin's noodling on whether this should be a two-layer approach: plain dotfiles that work when cloned to $XDG_CONFIG, with nix-darwin as an optional layer on top. The design will feel more obvious with time. Main symptom: occasional neovim config alerts when opening vim without home-manager applied.
