---
id: fort-89e.8
status: closed
deps: [fort-89e.6, fort-89e.7]
links: []
created: 2025-12-30T22:03:06.345789733Z
type: task
priority: 2
parent: fort-89e
---
# Migrate cert distribution to control plane

Switch SSL cert distribution from rsync-push to agent-pull:

1. Add fort.needs.ssl.wildcard to one test host (not forge/beacon)
2. Verify cert arrives via fulfillment and nginx reloads
3. Expand to all hosts
4. Remove acme-sync timer from certificate-broker

Storage: /var/lib/fort/ssl/<domain>/{fullchain.pem,key.pem,chain.pem}

This is the first end-to-end validation of the control plane.

## Acceptance Criteria

- All hosts receive certs via control plane
- nginx reloads after cert delivery
- acme-sync timer removed
- No regressions in SSL functionality


