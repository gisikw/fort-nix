---
id: fort-e2w.8
status: open
deps: [fort-e2w.7]
links: []
created: 2026-01-04T06:04:17.701949646Z
type: task
priority: 2
parent: fort-e2w
---
# Create backup failure alerts

Set up AlertManager rules for backup health.

Alerts to create:
- Backup older than 48 hours
- Backup job failed
- Cloud sync failed
- Repository integrity check failed

Reference: docs/backup-design.md section 8


