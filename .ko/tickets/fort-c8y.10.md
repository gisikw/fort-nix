---
id: fort-c8y.10
status: closed
deps: [fort-c8y.9]
links: []
created: 2026-01-08T04:02:34.078581096Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 3: Add provider state management

Persist provider state for async capabilities.

## Design

File: /var/lib/fort/provider-state.json
Schema: {capability -> {origin:need -> {request, response?, updated_at}}}

## Tasks

- [ ] Create provider state file structure
- [ ] Load state on fort-provider startup
- [ ] Persist state after handler runs
- [ ] Include request, response, and updated_at per origin:need

## Acceptance Criteria

- State persists across restarts
- State correctly tracks all active requests per capability
- State file is valid JSON


