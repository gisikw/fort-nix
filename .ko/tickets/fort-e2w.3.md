---
id: fort-e2w.3
status: open
deps: []
links: []
created: 2026-01-04T05:54:23.889235971Z
type: task
priority: 2
parent: fort-e2w
---
# Create restic password secret

Create shared restic repository password in agenix.

Tasks:
- Generate strong password
- Encrypt as restic-password.age
- Add to secrets.nix with appropriate host keys
- Document paper backup recommendation

Reference: docs/backup-design.md section 3 (Encryption Model)


