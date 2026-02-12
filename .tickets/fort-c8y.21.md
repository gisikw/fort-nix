---
id: fort-c8y.21
status: open
deps: [fort-c8y.15, fort-c8y.17, fort-c8y.18, fort-c8y.19, fort-c8y.20, fort-c8y.31, fort-c8y.32]
links: []
created: 2026-01-08T04:05:07.839901036Z
type: task
priority: 3
parent: fort-c8y
---
# Phase 5: Remove legacy mechanisms

Final cleanup after all migrations complete.

## Legacy Mechanisms to Remove

- acme-sync timer (replaced by ssl-cert callbacks)
- attic-key-sync timer (replaced by attic-token capability)
- service-registry aspect - decomposed into:
  - DNS: evaluate if should move to control plane or remain centralized
  - OIDC: replaced by oidc-register capability
  - Proxy: replaced by proxy-configure capability

## Tasks

- [ ] Remove acme-sync timer from certificate-broker
- [ ] Remove attic-key-sync timer from attic app
- [ ] Remove OIDC client management from service-registry
- [ ] Remove nginx vhost management from service-registry
- [ ] Evaluate DNS management (may remain in service-registry)
- [ ] Remove or simplify service-registry aspect

## Acceptance Criteria

- No SSH-based push mechanisms remain (except possibly DNS)
- All credential/config distribution via control plane
- Clean separation of concerns


