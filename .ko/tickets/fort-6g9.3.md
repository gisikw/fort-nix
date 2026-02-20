---
id: fort-6g9.3
status: closed
deps: []
links: []
created: 2025-12-31T20:23:53.695205024Z
type: task
priority: 2
parent: fort-6g9
---
# restart capability

Handler that restarts a systemd unit.

Request: { unit: "fort-agent" }
Response: { status: "restarted" } or error

Implementation: systemctl restart <unit>

Should validate unit name against allowlist to prevent arbitrary service restarts.

RBAC: Only dev-sandbox principal should be able to call this.


