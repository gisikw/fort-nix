---
id: fort-89e.25
status: closed
deps: []
links: []
created: 2026-01-07T02:08:34.957567488Z
type: task
priority: 2
parent: fort-89e
---
# Proxy vhost handles for GC-only lifecycle

Public proxy vhosts need handle-based lifecycle management even though the requester has no credential to act on.

## Context

When a host declares `fort.cluster.services` with `visibility = "public"`, it needs proxy config from the beacon. The beacon creates an nginx vhost, but unlike OIDC credentials or SSL certs, there's nothing the requester *does* with this - they just need the vhost to exist.

However, the handle mechanism is still essential for GC:
- Host requests proxy config → beacon creates vhost, returns handle
- Host stores handle in holdings
- Host is decommissioned (or service removed) → handle no longer advertised
- Beacon's GC sweep detects missing handle → cleans up orphaned vhost

## Design Questions

1. Should proxy-configure return a handle even when there's no credential payload?
2. How does fort-fulfill store a "GC-only" handle that has no transform/destination?
3. Should this be a distinct need type (e.g., `fort.needs.proxy` vs `fort.needs.oidc`)?

## Relationship to fort-89e.16/17

This is orthogonal to implementing the proxy-configure capability itself - it's about ensuring the handle lifecycle is wired correctly for the GC-only case.


