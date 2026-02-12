---
id: fort-c8y.1
status: closed
deps: []
links: []
created: 2026-01-07T06:33:33.079010531Z
type: task
priority: 2
parent: fort-c8y
---
# Audit existing implementation and create fresh implementation plan

Review the current codebase and prior design work, then produce a fresh implementation plan.

## Inputs

**Prior art (for context, not authority):**
- `docs/control-plane-design.md` - original architecture concepts
- `fort-89e` - original epic and its 24 child tickets

**Authoritative specification:**
- `docs/control-plane-interfaces.md` - the interfaces doc we iterated on

**Existing implementation:**
- RPC-style capabilities already working: `journal`, `restart`, `status`, `deploy`, `manifest`, `holdings`
- `fort-agent-call` client script
- Agent nginx/CGI infrastructure
- Whatever else is in the codebase

## Deliverable

A new implementation plan at `docs/control-plane-implementation.md` that:
1. Inventories what's already built and working
2. Identifies gaps between current state and the interfaces spec
3. Proposes implementation order with dependencies
4. Calls out any spec ambiguities discovered during audit

This plan will inform a fresh ticket breakdown under fort-c8y.

## Cleanup

Once the new tickets are created, close `fort-89e` and all its children as `wontdo` (superseded by this epic).


