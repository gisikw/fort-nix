---
id: fort-c8y.30
status: tombstone
deps: []
links: []
created: 2026-01-12T13:01:48.577882912Z
type: task
priority: 2
---
# Phase 5: Migrate DNS configuration to control plane

The service-registry aspect still manages DNS records via SSH push. This needs to migrate to control plane capabilities before fort-c8y.21 (legacy cleanup) can complete.

## Current State (registry.rb)

**Headscale DNS** (lines 56-64):
- Collects VPN IPs for all services
- SSHes to beacon, writes `/var/lib/headscale/extra-records.json`
- Enables `service.domain` resolution over tailnet

**CoreDNS/LAN DNS** (lines 66-71):
- Filters to non-vpn services
- SSHes to forge, writes `/var/lib/coredns/custom.conf`
- Enables `service.domain` resolution on LAN

## Target State

Two new capabilities:

1. **`dns-headscale`** on beacon (raishan)
   - Accepts: `{fqdn, ip}` records from hosts with exposed services
   - Writes: `/var/lib/headscale/extra-records.json`
   - Mode: async (like proxy-configure)

2. **`dns-coredns`** on forge (drhorrible)
   - Accepts: `{fqdn, ip}` records from hosts with non-vpn services
   - Writes: `/var/lib/coredns/custom.conf`
   - Mode: async

Alternatively, could be a single `dns-configure` capability if one host should own all DNS, but current architecture has them split.

## Implementation Notes

- Each host with `fort.cluster.services` would declare needs for DNS registration
- Similar pattern to `proxy-configure`: host manifest includes service info, needs trigger registration
- GC sweep cleans up stale records when services removed

## Acceptance Criteria

- [ ] DNS records managed via control plane, not SSH push
- [ ] Headscale extra-records populated from capability responses
- [ ] CoreDNS custom.conf populated from capability responses
- [ ] fort-c8y.21 unblocked



