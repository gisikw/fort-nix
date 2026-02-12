---
id: fort-c8y.15
status: closed
deps: [fort-c8y.6, fort-c8y.11]
links: []
created: 2026-01-08T04:03:41.12476294Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 4: Implement GC sweep (fort-provider-gc)

Garbage collect orphaned state from provider.

## Design

- Periodic service (e.g., 1h interval)
- For each async capability:
  - For each origin in provider state
  - Call POST /fort/needs on origin
  - If need not in response (and host reachable): remove from state
  - Invoke handler with updated state (for cleanup)

## Positive-absence rules

- Only delete on 200 + absence
- Network failures = assume still in use
- Host removed from cluster = immediate cleanup

## Tasks

- [ ] Create fort-provider-gc service and timer
- [ ] Query each origin for its needs list
- [ ] Compare against provider state
- [ ] Remove orphaned entries
- [ ] Invoke handler with cleaned state

## Acceptance Criteria

- Orphaned state cleaned up within GC interval
- Network failures do not cause premature cleanup
- Handler notified of removed consumers


