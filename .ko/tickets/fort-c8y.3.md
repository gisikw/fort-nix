---
id: fort-c8y.3
status: closed
deps: [fort-c8y.2]
links: []
created: 2026-01-08T04:00:57.58952355Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 1: Rename paths and services

Rename paths and systemd services to target convention.

## Tasks

- [ ] /agent/* -> /fort/* (nginx location in common/fort-agent.nix)
- [ ] /etc/fort-agent/ -> /etc/fort/
- [ ] /var/lib/fort-agent/ -> /var/lib/fort/ (consolidate)
- [ ] fort-fulfill.service -> fort-consumer.service
- [ ] fort-fulfill-retry.timer -> fort-consumer-retry.timer
- [ ] common/fort-agent.nix -> common/fort.nix (or merge)

## Acceptance Criteria

- All hosts deploy successfully with new paths
- Services start and function identically
- No /agent/ or fort-agent references remain in active config


