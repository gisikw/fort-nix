---
id: fort-e2w.5
status: open
deps: [fort-e2w.4]
links: []
created: 2026-01-04T05:58:54.242316083Z
type: task
priority: 2
parent: fort-e2w
---
# Set up Backblaze B2 cloud storage

Configure cloud offsite backup destination.

Tasks:
- Create Backblaze B2 bucket (or Cloudflare R2 if <10GB)
- Generate application key with write access
- Store credentials as agenix secret
- Configure rclone remote on backup hub

Reference: docs/backup-design.md section 6.1


