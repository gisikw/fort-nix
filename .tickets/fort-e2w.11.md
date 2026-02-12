---
id: fort-e2w.11
status: open
deps: []
links: []
created: 2026-01-04T06:04:40.662293434Z
type: task
priority: 2
parent: fort-e2w
---
# Add backup agent capabilities

Optional: expose backup operations via fort-agent API.

Capabilities to consider:
- backup-status: Last backup time, size, success/failure
- backup-trigger: Manually trigger backup from dev-sandbox
- backup-list: List available snapshots

Lives on backup hub, callable from dev-sandbox.

Reference: docs/backup-design.md section 7.3


