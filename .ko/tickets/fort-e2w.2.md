---
id: fort-e2w.2
status: open
deps: [fort-e2w.3]
links: []
created: 2026-01-04T05:54:21.323170286Z
type: task
priority: 2
parent: fort-e2w
---
# Create backup-client aspect

Create aspects/backup-client that configures hosts to push backups to the hub.

Tasks:
- Install restic package
- Configure services.restic.backups.system for /var/lib
- Add PostgreSQL backup job (if postgres enabled)
- Set up timer for daily backups with randomized delay

Reference: docs/backup-design.md section 7.1


