---
id: fort-e2w.6
status: open
deps: [fort-e2w.5]
links: []
created: 2026-01-04T05:58:57.681439177Z
type: task
priority: 2
parent: fort-e2w
---
# Configure nightly cloud sync

Set up automated sync from backup hub to cloud storage.

Tasks:
- Create systemd service for rclone sync
- Add timer (2 AM suggested)
- Verify encrypted blobs land in B2
- Test restore from cloud

Reference: docs/backup-design.md section 7.2


