---
id: fort-c8y.13
status: closed
deps: [fort-c8y.11]
links: []
created: 2026-01-08T04:03:11.543653816Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 3: Add boot-time initialization

Run async handlers on boot for triggers.initialize capabilities.

## Design

- If triggers.initialize = true, run handler on service start
- Load persisted state, invoke handler, dispatch callbacks

## Tasks

- [ ] Check triggers.initialize for each capability on startup
- [ ] Load existing provider state
- [ ] Invoke handler with current state
- [ ] Dispatch callbacks for any responses

## Acceptance Criteria

- Handlers with triggers.initialize run on fort-provider start
- Existing state is loaded and passed to handler
- Callbacks dispatched for initial responses


