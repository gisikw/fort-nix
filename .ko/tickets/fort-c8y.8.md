---
id: fort-c8y.8
status: closed
deps: [fort-c8y.4]
links: []
created: 2026-01-08T04:02:08.626862093Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 2: Simplify need options schema

Replace current need options with handler-based model.

## Current Schema
- providers (list)
- store, transform, restart, reload
- identity

## Target Schema
- from (single provider)
- handler (script)
- nag (duration, default 15m)
- request

## Tasks

- [ ] Add "from" option (single string, not list)
- [ ] Add "handler" option (path to script)
- [ ] Add "nag" option (duration string -> seconds, default 15m)
- [ ] Remove store/transform/restart/reload/identity
- [ ] Update option type definitions in fort.nix

## Acceptance Criteria

- New schema accepted by Nix module
- Old schema rejected with clear error
- Handler invoked with response on stdin


