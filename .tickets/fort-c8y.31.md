---
id: fort-c8y.31
status: closed
deps: []
links: []
created: 2026-01-12T13:02:20.747886438Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 5: Migrate Headscale DNS to control plane

Migrate Headscale extra-records management from SSH push to control plane capability.

## Current State (service-registry/registry.rb lines 56-64)

- Collects VPN IPs for all services across cluster
- SSHes to beacon (raishan), writes `/var/lib/headscale/extra-records.json`
- Enables `service.domain` resolution over tailnet

## Target State

**`dns-headscale` capability** on beacon (raishan):
- Mode: async
- Accepts: `{fqdn, ip}` records from hosts with exposed services  
- Writes: `/var/lib/headscale/extra-records.json`
- Triggers: systemd (on headscale restart)

**Consumer side** (hosts with `fort.cluster.services`):
- Declare `fort.host.needs.dns-headscale.<service>` for each exposed service
- Request includes: fqdn, vpn_ip

## Implementation Notes

- Similar pattern to `proxy-configure`
- GC sweep cleans up stale records when services removed
- Handler aggregates all active requests into single extra-records.json

## Acceptance Criteria

- [ ] `dns-headscale` capability on beacon
- [ ] Hosts with services declare dns-headscale needs
- [ ] extra-records.json populated from capability state
- [ ] SSH push removed from service-registry for this path



