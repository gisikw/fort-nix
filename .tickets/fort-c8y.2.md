---
id: fort-c8y.2
status: closed
deps: []
links: []
created: 2026-01-08T04:00:44.412792483Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 1: Rename packages (fort-agent-* to fort-*)

Rename existing packages to target naming convention.

## Tasks

- [ ] pkgs/fort-agent-wrapper/ -> pkgs/fort-provider/
- [ ] pkgs/fort-agent-call/ -> pkgs/fort/
- [ ] Update CLI to make request arg optional (default {})
- [ ] Update all references in common/fort-agent.nix

## Acceptance Criteria

- fort drhorrible status works (no empty {} required)
- fort-provider package builds and works identically to old wrapper
- No functional changes, just naming


