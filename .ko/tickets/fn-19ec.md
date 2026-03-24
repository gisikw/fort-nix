---
id: fn-19ec
status: open
deps: []
created: 2026-03-23T17:52:50Z
type: task
priority: 2
---
# Manual renewal needed; consumers ignore updates.

SSL cert renewal doesn't auto-push to consumers — provider trigger fires but consumers already show fulfilled, so they ignore the update. Requires manual force-nag on every host.
