---
id: fort-c8y.26
status: open
deps: []
links: []
created: 2026-01-11T17:41:58.83987654Z
type: task
priority: 3
parent: fort-c8y
---
# Review git-token TTL for provider-side GC

The git-token capability previously had a 30-day TTL (ttl = 86400 * 30) for client-side enforcement. With the move to mode-based schema (fort-c8y.9), it now uses the default 24h TTL derived from async mode.

## Context

- Old: explicit `ttl = 86400 * 30` (30 days)
- New: derived from `mode = "async"` → ttl = 86400 (24h default)

## Questions to resolve

- Is 30-day TTL important for git tokens, or is 24h fine?
- How does this interact with provider-side GC?
- Should TTL be configurable per-capability for async mode, or is a cluster-wide default sufficient?

## Acceptance criteria

- Decide on appropriate TTL for git-token handles
- Implement if different from default


