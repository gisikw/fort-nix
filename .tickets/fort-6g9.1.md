---
id: fort-6g9.1
status: closed
deps: []
links: []
created: 2025-12-31T20:23:43.709735031Z
type: task
priority: 2
parent: fort-6g9
---
# deploy capability (trigger comin)

Handler that triggers comin for on-demand deploy.

Request: {} (no params needed)
Response: { status: "triggered" } or error

Implementation: systemctl start comin (or comin fetch && comin apply)

Should be available on all hosts but particularly useful for forge/beacon
which stay off automatic GitOps.

RBAC: Only dev-sandbox principal should be able to call this.


