---
id: fort-e2w.12
status: open
deps: [fort-e2w.10]
links: []
created: 2026-01-04T06:04:54.189475849Z
type: task
priority: 2
parent: fort-e2w
---
# Set up peer backup exchange

Configure offsite peer backup with trusted party.

Tasks:
- Coordinate with peer on hosting arrangement
- Deploy restic REST server on peer's Linux box (Docker or native)
- Set up WireGuard/Tailscale tunnel for secure transport
- Configure sync from backup hub to peer
- Verify encrypted blobs land on peer
- Document mutual backup arrangement

This provides a third copy (beyond local + cloud) with geographic diversity.

Reference: docs/backup-design.md section 6.2, Phase 5


