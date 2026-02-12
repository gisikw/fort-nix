---
id: fort-c8y.7
status: closed
deps: [fort-c8y.4]
links: []
created: 2026-01-08T04:01:52.56273974Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 2: Add consumer state tracking

Track fulfillment state for nag-based retry.

## Design

File: /var/lib/fort/consumer-state.json
Schema: {need_id -> {satisfied: bool, last_sought: timestamp}}

## Tasks

- [ ] Create consumer state file on first run
- [ ] Update fort-consumer to check satisfied before requesting
- [ ] Track last_sought timestamp
- [ ] Implement nag-based retry (only request if unsatisfied AND past nag interval)
- [ ] Mark satisfied = true when callback received

## Acceptance Criteria

- Consumer only requests unsatisfied needs
- Nag interval (default 15m) respected
- State persists across restarts


