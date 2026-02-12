---
id: fort-89e.20
status: closed
deps: [fort-89e.15, fort-89e.19]
links: []
created: 2025-12-30T22:06:15.47832576Z
type: task
priority: 2
parent: fort-89e
---
# Enable GC sweeps

Provider-side garbage collection:

1. Add GC timer to forge (and beacon if needed)
2. For each capability with needsGC:
   - Get list of issued handles from provider state
   - For each handle, check holder's /agent/holdings
   - If 200 + handle absent: mark eligible (after grace period)
   - If 200 + handle present: still in use
   - If error: assume still in use (two-generals safe)
3. Sweep eligible handles:
   - OIDC: delete pocket-id client
   - Git tokens: revoke Forgejo token
   - Attic tokens: revoke attic token

Grace period: configurable, default 1 hour?

## Acceptance Criteria

- GC timer runs on providers
- Orphan credentials identified correctly
- Credentials revoked after grace period
- No false positives (never revoke in-use credentials)


