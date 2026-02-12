---
id: fort-2zl
status: open
deps: []
links: []
created: 2026-01-01T17:51:24.193238664Z
type: task
priority: 2
---
# Make attic cache inclusion resilient to network failure

When cache.gisi.network is unreachable, builds should proceed without the cache rather than blocking.

Options:
- Use nix's fallback-if-missing behavior
- Check connectivity before including
- Set appropriate timeouts

Context: During 2026-01-01 outage, builds were blocked because the attic cache was unreachable over the down tailnet.


