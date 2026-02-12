---
id: fort-e2w.7
status: open
deps: [fort-e2w.6]
links: []
created: 2026-01-04T06:04:13.131606209Z
type: task
priority: 2
parent: fort-e2w
---
# Add backup metrics to observability stack

Integrate backup health into fort-observability.

Tasks:
- Export Prometheus metrics: backup age, size, duration per host
- Create backup health check service on hub
- Add Grafana dashboard for backup status
- Consider restic-exporter or custom metrics

Reference: docs/backup-design.md section 8


