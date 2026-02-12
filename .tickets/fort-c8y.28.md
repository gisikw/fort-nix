---
id: fort-c8y.28
status: closed
deps: []
links: []
created: 2026-01-12T04:13:55.56992409Z
type: task
priority: 2
parent: fort-c8y
---
# Add force-nag capability for immediate retry

## Context

During fort-c8y.19 debugging, had to wait ~15 minutes for the nag interval to expire before a fixed handler would be retried. This is friction for operational debugging.

## Proposal

Add a mechanism to force immediate retry of unsatisfied needs, bypassing the nag interval. Options:

1. **New capability**: `fort <host> nag '{"need": "oidc-register-outline"}'` or `fort <host> nag '{}'` for all
2. **Extend restart**: `fort <host> restart '{"unit": "fort-consumer", "clear_nag": true}'`
3. **State file manipulation**: Clear the nag timestamp file directly

The first option feels cleanest - a dedicated `nag` capability on fort-consumer that clears nag state and triggers immediate retry.

## Acceptance

- Can force immediate retry of a specific need or all needs
- Works from dev-sandbox via `fort <host> nag`


