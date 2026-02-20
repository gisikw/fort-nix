---
id: fort-89e.9
status: closed
deps: [fort-89e.4, fort-89e.5]
links: []
created: 2025-12-30T22:03:29.654479207Z
type: task
priority: 2
parent: fort-89e
---
# git-token capability

Handler on forge that creates/returns Forgejo deploy tokens:

Request: { host: "ursula", access: "rw" | "ro" }
Response: { token: "..." }
Handle: yes (for GC when host removed)

Uses Forgejo API via forge-admin service account.
Replaces forgejo-deploy-token-sync timer logic.

RBAC: hosts with dev-sandbox aspect get rw, others get ro.

## Acceptance Criteria

- Handler creates deploy token via Forgejo API
- Returns handle for GC tracking
- Token has correct access level based on request


