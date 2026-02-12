---
id: fort-e2w.1
status: open
deps: [fort-e2w.3]
links: []
created: 2026-01-04T05:54:16.051730683Z
type: task
priority: 2
parent: fort-e2w
---
# Set up restic REST server on ursula

Deploy restic REST server with append-only mode on ursula. This is the backup hub that receives backups from all other hosts.

Tasks:
- Add backup-hub app or role to apps/
- Configure REST server with append-only and private-repos
- Expose via nginx (vpn visibility only)
- Store repos on ZFS pool

Reference: docs/backup-design.md section 7.2


