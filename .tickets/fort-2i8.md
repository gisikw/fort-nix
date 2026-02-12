---
id: fort-2i8
status: closed
deps: []
links: []
created: 2025-12-21T11:41:09.489375-06:00
type: task
priority: 2
---
# Improve deploy-rs failure debugging

When deploy-rs fails, currently requires SSH + journalctl to diagnose. Options: capture activation logs, surface systemd failures in deploy output, or create a 'just diagnose <host>' helper that pulls recent failures.


