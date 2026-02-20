---
id: fort-89e.15
status: closed
deps: [fort-89e.4]
links: []
created: 2025-12-30T22:04:52.341823463Z
type: task
priority: 1
parent: fort-89e
---
# Holdings management and GC foundation

Infrastructure for distributed GC:

1. /var/lib/fort/holdings.json structure: { handles: ["sha256:...", ...] }
2. Helper scripts: fort-holdings-add, fort-holdings-remove
3. Wire holdings endpoint to return this file
4. Release endpoint (self-release mode):
   - Remove handles from holdings.json
   - Notify relevant providers

Provider-side GC (checking holdings, sweeping orphans) is separate ticket.

## Acceptance Criteria

- holdings.json maintained correctly
- Holdings endpoint returns current handles
- Release endpoint removes handles and notifies providers


