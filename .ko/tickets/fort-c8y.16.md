---
id: fort-c8y.16
status: closed
deps: [fort-c8y.8, fort-c8y.12]
links: []
created: 2026-01-08T04:03:55.967891437Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 5: Migrate git-token to new schema

First migration - validates new infrastructure on working capability.

## Current State

- git-token capability working (RPC style)
- gitops aspect: fort.host.needs.git-token.default (RO)
- dev-sandbox aspect: fort.host.needs.git-token.dev (RW)
- Uses old schema: providers, store, transform

## Target State

- New schema: from, handler
- Write handler scripts for gitops and dev-sandbox
- Remove store/transform usage

## Tasks

- [ ] Write git-token handler for gitops (stores token, no restart needed)
- [ ] Write git-token handler for dev-sandbox (stores token)
- [ ] Migrate gitops need declaration to new schema
- [ ] Migrate dev-sandbox need declaration to new schema
- [ ] Test both RO and RW token flows

## Acceptance Criteria

- git clone/push still works after migration
- No regressions in comin pulls
- Dev sandbox push access works


