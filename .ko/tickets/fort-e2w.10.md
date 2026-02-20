---
id: fort-e2w.10
status: open
deps: [fort-e2w.8]
links: []
created: 2026-01-04T06:04:37.87005573Z
type: task
priority: 2
parent: fort-e2w
---
# Implement backup verification tests

Automated verification that backups are restorable.

Options:
- restic check (repository integrity)
- Periodic test restore to ephemeral VM
- Smoke tests on restored data

Start with restic check, consider automated restore testing later.

Reference: docs/backup-design.md section 9 (Periodic Recovery Testing)


