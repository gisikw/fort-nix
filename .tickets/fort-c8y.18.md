---
id: fort-c8y.18
status: closed
deps: [fort-c8y.16]
links: []
created: 2026-01-08T04:04:25.221798775Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 5: Migrate Attic cache tokens to control plane

Replace attic-key-sync SSH push with control plane.

## Current State

- attic-key-sync timer pushes cache config + tokens via SSH
- No capability defined

## Target State

- attic-token capability on attic host
- Consumers declare fort.host.needs.attic-token.default
- Callback delivers token
- Remove attic-key-sync timer

## Tasks

- [ ] Create attic-token capability handler
- [ ] Write consumer handler (stores token + cache config)
- [ ] Add fort.host.needs.attic-token.default to hosts
- [ ] Test cache push from gitops hosts
- [ ] Remove attic-key-sync timer

## Acceptance Criteria

- All hosts receive attic tokens via control plane
- Cache push works from gitops post-deploy


