---
id: fort-576
status: open
deps: []
links: []
created: 2026-01-01T17:51:38.500340467Z
type: task
priority: 2
---
# Add alerting for failed systemd services across cluster

Proactive alerting when any host has failed systemd units, rather than discovering them while debugging other issues.

Could integrate with fort-agent status endpoint which already reports failed_units count.


