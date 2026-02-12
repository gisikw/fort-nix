---
id: fort-c8y.11
status: closed
deps: [fort-c8y.10]
links: []
created: 2026-01-08T04:02:47.538180977Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 3: Implement async handler invocation

Invoke async handlers with aggregate request/response state.

## Design

- On new request: add to state, invoke handler with ALL requests, update responses
- On trigger: invoke handler, compare responses, callback if changed
- Handler input: {origin:need -> {request, response}}
- Handler output: {origin:need -> response}

## Tasks

- [ ] Build aggregate input from provider state
- [ ] Invoke handler with aggregate JSON on stdin
- [ ] Parse aggregate output
- [ ] Diff responses to detect changes
- [ ] Update provider state with new responses

## Acceptance Criteria

- Handler receives all active requests
- Handler can return responses for any/all requests
- Changed responses detected for callback dispatch


