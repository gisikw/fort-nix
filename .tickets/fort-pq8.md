---
id: fort-pq8
status: closed
deps: []
links: []
created: 2025-12-31T07:20:34.162211912Z
type: task
priority: 3
---
# Integrate home-manager in dev-sandbox using home-config input

## Context

fort-67y added cluster-level flakes with home-config input. The input is now available in dev-sandbox via extraInputs.home-config, but nothing uses it yet.

## Work Needed

1. Import home-manager's NixOS module in dev-sandbox aspect
2. Configure home-manager.users.dev to use the home-config flake
3. Determine how the github:gisikw/config flake exports its config and wire it up appropriately

## Files
- aspects/dev-sandbox/default.nix (main changes)
- Possibly clusters/bedlam/hosts/ratched/flake.nix if home-manager module needs to be passed through


