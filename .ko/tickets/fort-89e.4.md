---
id: fort-89e.4
status: closed
deps: [fort-89e.1, fort-89e.2, fort-89e.3]
links: []
created: 2025-12-30T22:01:29.957039978Z
type: task
priority: 2
parent: fort-89e
---
# Mandatory agent endpoints

Implement mandatory endpoints as bash handlers:
- status: return {version, uptime, hostname}
- manifest: return contents of /var/lib/fort/host-manifest.json
- holdings: return contents of /var/lib/fort/holdings.json

These have no RBAC (any cluster host can call). Deploy agent to forge initially for testing.

Note: release endpoint deferred to GC phase.

## Acceptance Criteria

- All three endpoints return valid JSON
- Endpoints work without RBAC restrictions
- Agent deployed and functional on forge


