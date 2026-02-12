---
id: fort-c8y.12
status: closed
deps: [fort-c8y.11, fort-c8y.5]
links: []
created: 2026-01-08T04:02:59.834830268Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 3: Implement callback dispatch

Push responses to consumer callback endpoints.

## Design

- After handler returns, POST responses to consumer callback endpoints
- Fire-and-forget (ignore response status)
- Return 202 to original request for async capabilities

## Tasks

- [ ] For each changed response, POST to consumer /fort/needs/<type>/<id>
- [ ] Use fort (CLI) or direct HTTP for callbacks
- [ ] Fire-and-forget - log failures but do not retry
- [ ] Return 202 Accepted for async capability requests

## Acceptance Criteria

- Changed responses trigger callbacks to consumers
- Callbacks are fire-and-forget
- Original request gets 202 for async capabilities


