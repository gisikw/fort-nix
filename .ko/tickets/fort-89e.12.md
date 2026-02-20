---
id: fort-89e.12
status: closed
deps: [fort-89e.11, fort-89e.7]
links: []
created: 2025-12-30T22:04:21.39373523Z
type: task
priority: 2
parent: fort-89e
---
# Migrate attic token distribution to control plane

Switch attic token distribution to agent-pull:

1. Add fort.needs.attic-token to relevant hosts/aspects
2. Store token at existing location
3. Verify nix builds can push to cache
4. Remove old distribution mechanism from attic app

Review apps/attic/ to identify current distribution pattern.

## Acceptance Criteria

- Hosts receive attic tokens via control plane
- Nix builds successfully push to cache
- Old distribution mechanism removed


