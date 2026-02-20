---
id: fort-89e.13
status: closed
deps: [fort-89e.4, fort-89e.5]
links: []
created: 2025-12-30T22:04:44.908884915Z
type: task
priority: 2
parent: fort-89e
---
# oidc-register capability

Handler on forge that registers OIDC clients in pocket-id:

Request: { service: "outline", fqdn: "outline.example.com" }
Response: { client_id: "...", client_secret: "..." }
Handle: yes (client ID for GC)

Uses pocket-id API via service key.
Replaces create_pocketid_client logic in service-registry.

RBAC: all hosts (simplest) or hosts with SSO-enabled services.

## Acceptance Criteria

- Handler creates OIDC client via pocket-id API
- Returns client_id and client_secret
- Returns handle for GC tracking


