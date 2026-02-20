---
id: fort-c8y.6
status: closed
deps: [fort-c8y.4]
links: []
created: 2026-01-08T04:01:37.087993272Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 2: Add needs enumeration endpoint

Add endpoint for GC to query what needs a host declares.

## Design

Route: POST /fort/needs
Response: {"needs": ["type/id", ...]}
Source: build-time generated list (static, no runtime file read)

## Tasks

- [ ] Generate static needs list at build time in Nix
- [ ] Add /fort/needs route to fort-provider
- [ ] Return JSON list of declared needs

## Acceptance Criteria

- POST /fort/needs returns list of all declared needs
- Response is static (no runtime file dependency)
- Works for hosts with no needs (empty list)


