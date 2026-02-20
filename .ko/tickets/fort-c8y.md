---
id: fort-c8y
status: open
deps: []
links: []
created: 2026-01-07T06:33:16.233561494Z
type: epic
priority: 2
---
# Runtime control plane v2

Revised control plane design based on learnings from fort-89e implementation.

## Authoritative Design

**`docs/control-plane-interfaces.md`** is the authoritative specification.

Key design decisions:
- Fire-and-forget communication with nag-based reliability
- Handlers receive all active requests, return all responses (no incremental mode)
- `mode = "rpc"` for synchronous request-response (journal, restart, status)
- `cacheResponse = true` for credentials that shouldn't churn (PATs)
- `triggers = { initialize, systemd }` for boot and event-driven reconciliation
- GC sweep doubles as periodic reconciliation
- Provider state: `{capability → {origin:need → {request, response?, updated_at}}}`

## Prior Art

- `docs/control-plane-design.md` - original architecture doc (some concepts superseded)
- `fort-89e` - original epic with partial implementation

## Current State

RPC-style capabilities (`journal`, `restart`, `status`, `deploy`) are already working. The async/orchestrated flow for credential distribution is not yet implemented.

## Next Steps

See child tickets for audit and implementation planning work.


