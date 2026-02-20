---
id: fort-89e.14
status: closed
deps: [fort-89e.13, fort-89e.7]
links: []
created: 2025-12-30T22:04:48.686666459Z
type: task
priority: 2
parent: fort-89e
---
# Migrate outline to control plane OIDC

First OIDC consumer migration:

1. Add fort.needs.oidc.outline to outline app
2. Store at /var/lib/fort/oidc/outline/{client-id,client-secret}
3. Update outline config to read from new location (or symlink)
4. Verify outline SSO login works

This validates the OIDC flow end-to-end before migrating other services.

## Acceptance Criteria

- Outline receives OIDC creds via control plane
- SSO login works
- No manual credential setup required


