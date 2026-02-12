---
id: fort-6g9.2
status: closed
deps: []
links: []
created: 2025-12-31T20:23:53.630208397Z
type: task
priority: 2
parent: fort-6g9
---
# journal capability

Handler that returns journalctl output for a unit.

Request: { unit: "fort-agent", lines: 50, since: "5 min ago" }
Response: { lines: [...] } or { output: "..." }

Implementation: journalctl -u <unit> -n <lines> --since <since> --no-pager

RBAC: Only dev-sandbox principal should be able to call this.


