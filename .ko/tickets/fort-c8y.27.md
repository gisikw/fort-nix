---
id: fort-c8y.27
status: open
deps: []
links: []
created: 2026-01-11T23:16:49.342730893Z
type: task
priority: 3
parent: fort-c8y
---
# Handle principal GC pattern for async capabilities

Principals (like dev-sandbox) can request async capabilities but can't be queried for their needs since they don't have a fort-agent endpoint.

Currently GC correctly skips them on "network failure" due to positive-absence rules, but this means principal entries never get cleaned up.

## Options

1. **Prohibit async for principals**: Only allow RPC-mode capabilities for principal callers
2. **TTL-based expiry for principals**: Use handle TTL expiry instead of needs-based GC
3. **Separate principal tracking**: Different GC mechanism (e.g., principal must periodically refresh)
4. **Build-time cleanup**: When principal removed from cluster, clean up at next deploy

## Current behavior

- Principal requests async capability → entry added to provider state
- GC runs → tries to query principal's /fort/needs → fails (no endpoint)
- Positive-absence rule → skip, don't delete
- Entry stays forever

## Context

Discovered during fort-c8y.15 implementation. The dev-sandbox principal has a git-token entry that will never be GC'd under current rules.


