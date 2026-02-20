---
id: fort-c8y.20
status: closed
deps: [fort-c8y.16]
links: []
created: 2026-01-08T04:04:54.29699454Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 5: Migrate proxy configuration to control plane

Replace service-registry nginx vhost management with control plane.

## Current State

- service-registry generates nginx vhost configs for public services
- Pushes to beacon via SSH

## Target State

- proxy-configure capability on beacon
- Consumers declare fort.host.needs.proxy.<servicename>
- Aggregate handler manages vhost configs
- GC removes vhosts when need disappears

## Tasks

- [ ] Create proxy-configure capability handler (aggregate)
- [ ] Handler generates and applies nginx vhost configs
- [ ] Write consumer handler (just confirms receipt)
- [ ] Add fort.host.needs.proxy.* declarations for public services
- [ ] Test public service routing
- [ ] Remove proxy management from service-registry

## Acceptance Criteria

- Beacon nginx configs managed via control plane
- Public services accessible
- Orphaned vhosts cleaned up by GC


