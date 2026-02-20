---
id: fort-5bj
status: closed
deps: []
links: []
created: 2025-12-31T21:28:41.378134064Z
type: bug
priority: 3
---
# fort-agent needs restart after deploy to pick up new config

The fort-agent service loads config files (rbac.json, capabilities.json, hosts.json) once at startup. After a deploy that updates these files, the service continues using the old config until manually restarted.

**Observed**: After deploying new capabilities (journal, restart), they returned 404 until the service was restarted.

**Fix options**:
1. Add `restartTriggers` to the systemd service to restart on config changes
2. Use `ExecReload` and `ReloadPropagatedFrom` for graceful reload
3. Have the Go wrapper watch for config file changes

Option 1 is simplest for a socket-activated service.


