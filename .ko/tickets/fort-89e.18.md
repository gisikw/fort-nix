---
id: fort-89e.18
status: closed
deps: [fort-89e.4, fort-89e.5]
links: []
created: 2025-12-30T22:06:04.752994195Z
type: task
priority: 2
parent: fort-89e
---
# DNS update capabilities

Handlers for DNS record management:

1. headscale-dns (beacon): Update /var/lib/headscale/extra-records.json
   - Request: { records: [{name, type, value}, ...] }
   - Manages MagicDNS entries for VPN-internal resolution

2. coredns-update (forge): Update /var/lib/coredns/custom.conf  
   - Request: { records: [{ip, fqdn}, ...] }
   - Manages LAN DNS entries

These replace the DNS update logic in service-registry.
May need to rethink: currently service-registry computes all records centrally.
With pull model, each host would declare its own records? Or forge aggregates?

## Design

Open question: per-host DNS declarations vs centralized computation. 
Current model scans all hosts and computes full record set.
Pull model options:
A) Each host declares its DNS records as needs (inverted - host pushes to DNS provider)
B) DNS providers poll hosts for their desired records
C) Hybrid - fulfillment on DNS hosts pulls manifest from each host

Leaning toward (A) with 'dns-register' capability - host says 'please add this A record'.

## Acceptance Criteria

- DNS records updated via control plane
- Both headscale and coredns records managed
- Old service-registry DNS logic removable


