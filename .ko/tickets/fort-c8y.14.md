---
id: fort-c8y.14
status: closed
deps: [fort-c8y.11]
links: []
created: 2026-01-08T04:03:25.969143276Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 3: Add systemd triggers

Re-run handlers when specified systemd units complete.

## Design

- For each triggers.systemd unit, watch for completion
- On trigger: re-invoke handler, diff responses, callback changes
- Fires after unit succeeds

## Tasks

- [ ] Generate systemd path/service units for each trigger
- [ ] Watch for unit success (not just activation)
- [ ] Invoke handler on trigger
- [ ] Diff and dispatch callbacks for changes

## Acceptance Criteria

- Handler re-runs when trigger unit succeeds
- Only changed responses trigger callbacks
- Works for ACME renewal trigger


