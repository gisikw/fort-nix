---
id: fort-89e.5
status: closed
deps: []
links: []
created: 2025-12-30T22:02:05.246179199Z
type: task
priority: 2
parent: fort-89e
---
# fort.needs / fort.capabilities option types

Nix module options for declaring needs and capabilities:

fort.needs.<type>.<name>:
- providers: list of hostnames
- request: attrset passed to capability
- store: path to store response (null = don't store)
- restart: list of services to restart after fulfillment

fort.capabilities.<name>:
- handler: path to handler script
- needsGC: bool (adds handle wrapper, GC timer)
- description: human-readable

Generate:
- /var/lib/fort/needs.json from all fort.needs declarations
- /etc/fort-agent/rbac.json from capabilities + topology
- Handler wrappers in /etc/fort-agent/handlers/

Minimal implementation for slice 1 - can expand later.

## Acceptance Criteria

- Options defined and documented
- needs.json generated correctly
- rbac.json generated from topology
- Handlers installed in correct location


