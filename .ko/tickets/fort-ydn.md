---
id: fort-ydn
status: open
deps: []
links: []
created: 2026-01-01T17:53:56.456498928Z
type: task
priority: 2
---
# Generalize restart capability to systemd capability

Replace the single-purpose 'restart' capability with a general 'systemd' capability that supports multiple actions:

```json
{"action": "restart", "unit": "nginx", "delay": 2}
{"action": "failed"}  // list failed units  
{"action": "status", "unit": "nginx"}  // specific unit status
{"action": "list", "pattern": "fort-*"}  // list matching units
```

This avoids capability sprawl and provides a single interface for systemd operations.

Context: During 2026-01-01 after-action, drhorrible showed 1 failed unit but we couldn't identify it - only the count was available via status endpoint.

Note: drhorrible's failed unit appears to have recovered on its own.


