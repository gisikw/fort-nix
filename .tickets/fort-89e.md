---
id: fort-89e
status: closed
deps: []
links: []
created: 2025-12-28T05:10:28.14077079Z
type: epic
priority: 3
---
# Unified runtime control plane

Replace the current fragmented credential delivery and service discovery mechanisms with a unified agent-based control plane.

## Design Document

See `docs/control-plane-design.md` for full technical design.

## Architecture Summary

**Agent:** Generic capability-exposure mechanism. Every host runs one. CGI handlers behind nginx at `/agent/*`. Auth via SSH signatures, RBAC from cluster topology. All POST. Handle/TTL in response headers for GC.

**Fulfillment:** How hosts resolve their needs at activation. `fort-fulfill.service` reads `needs.json`, calls providers, stores results. Best-effort (doesn't block deploy). Timer retries failures.

**Holdings Protocol:** Distributed GC. Providers return handles, callers advertise them via `/agent/holdings`. Positive absence triggers cleanup.

**Two providers:**
- **Forge** (drhorrible): Identity & secrets - OIDC registration, SSL certs, git tokens
- **Beacon** (raishan): Network edge - public proxy config

## Nix Abstractions

- `fort.needs.*` - Apps declare what they need, system generates needs.json
- `fort.capabilities.*` - Providers declare what they expose, system generates handlers + RBAC
- `needsGC = true` - Auto-wires handle headers and GC timer

## Key Decisions

- Hosts pull from providers (not push-based)
- Deploy resilience: fulfillment is best-effort, never blocks deploy
- CGI-style handlers (bash scripts, upgradeable to Go/Rust per-endpoint)
- Holdings protocol for distributed GC (two-generals safe)

## Related Tickets

- fort-c33: Consolidate fortCluster options under fort.cluster (absorb into this epic)
- fort-0rj: Group-based OIDC client restrictions (adjacent, not blocking)
- fort-bkv: Typo bug in outline tmpfiles (quick fix)

## Migration Path

1. Add agent to all hosts (mandatory endpoints: status, manifest, holdings, release)
2. Add forge capabilities (oidc-register, ssl-cert, git-token)
3. Add beacon capabilities (proxy-configure)
4. Add fort-fulfill.service
5. Run in parallel with existing SSH-based mechanisms
6. Validate all coordination patterns
7. Remove SSH-based delivery (service-registry, acme-sync, token-sync)
8. Enable GC sweeps

## Audit Notes (from codebase review)

- Only outline uses sso.mode="oidc" directly (forgejo has custom setup)
- 17 apps use custom subdomains (goes in request field)
- Path consolidation needed: various /var/lib/fort-* paths → /var/lib/fort/
- Current beacon is passive (receives nginx config via SCP) - needs real provider implementation


