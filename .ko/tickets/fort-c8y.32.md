---
id: fort-c8y.32
status: closed
deps: []
links: []
created: 2026-01-12T13:02:32.975590473Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 5: Migrate CoreDNS to control plane

Migrate CoreDNS custom.conf management from SSH push to control plane capability.

## Current State (service-registry/registry.rb lines 66-71)

- Filters to non-vpn visibility services
- SSHes to forge (drhorrible), writes `/var/lib/coredns/custom.conf`
- Enables `service.domain` resolution on LAN

## Target State

**`dns-coredns` capability** on forge (drhorrible):
- Mode: async
- Accepts: `{fqdn, lan_ip}` records from hosts with non-vpn services
- Writes: `/var/lib/coredns/custom.conf`
- Triggers: systemd (on coredns restart)

**Consumer side** (hosts with non-vpn `fort.cluster.services`):
- Declare `fort.host.needs.dns-coredns.<service>` for each non-vpn service
- Request includes: fqdn, lan_ip

## Implementation Notes

- Similar pattern to `proxy-configure`
- Only services with `visibility != "vpn"` need LAN DNS
- GC sweep cleans up stale records when services removed
- Handler aggregates all active requests into hosts-style custom.conf

## Acceptance Criteria

- [ ] `dns-coredns` capability on forge
- [ ] Hosts with non-vpn services declare dns-coredns needs
- [ ] custom.conf populated from capability state
- [ ] SSH push removed from service-registry for this path



