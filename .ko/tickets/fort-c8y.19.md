---
id: fort-c8y.19
status: closed
deps: [fort-c8y.16]
links: []
created: 2026-01-08T04:04:39.178299072Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 5: Migrate OIDC registration to control plane

Replace service-registry OIDC client management with control plane.

## Current State

- service-registry creates/deletes pocket-id clients
- Based on exposed services with SSO enabled

## Target State

- oidc-register capability on identity provider (drhorrible)
- Consumers declare fort.host.needs.oidc.<servicename>
- Aggregate handler manages all clients
- Callback delivers client_id + client_secret
- GC removes clients when need disappears

## Implementation Status (IN PROGRESS)

### Completed
- [x] Create oidc-register capability handler in pocket-id app
- [x] Add auto-generation of oidc needs in fort.nix for SSO services
- [x] Remove OIDC management from service-registry
- [x] Deploy all hosts (drhorrible, q, ratched, joker, lordhenry, minos, ursula, raishan)

### Bug Fixes Applied
- Fixed jq array concatenation in handler (commit 8d51d26)
- Fixed jq select expression to properly return null

### Pending
- [ ] Wait for nag interval to expire (~5 min from last check at 03:50 UTC)
- [ ] Verify OIDC registration succeeds on q (has outline, silverbullet, termix)
- [ ] Verify on ratched (has flatnotes, vdirsyncer-auth)
- [ ] Re-enable GC in handler (currently commented out for safe rollout)
- [ ] Redeploy drhorrible with GC enabled
- [ ] Close ticket

### GC Code Location
File: apps/pocket-id/default.nix, lines 175-186
The GC code is commented out with `# TODO(fort-c8y.19)` marker.
Uncomment to enable deletion of all unaccounted-for OIDC clients.

### Key Files Changed
- apps/pocket-id/default.nix - oidc-register capability handler
- common/fort.nix - auto-generates oidc needs for SSO services  
- aspects/service-registry/registry.rb - removed OIDC management

### Testing Command
```bash
fort q restart '{"unit": "fort-consumer"}'
fort q journal '{"unit": "fort-consumer", "lines": 30, "since": "1 min ago"}'
fort q status  # Check consumer_state for oidc-register-* entries
```

## Acceptance Criteria

- OIDC clients created via control plane
- Credentials delivered to consumers
- Orphaned clients cleaned up by GC
- This is the canonical aggregate capability example

Depends on (2):
  → fort-c8y: Runtime control plane v2 [P2]
  → fort-c8y.16: Phase 5: Migrate git-token to new schema [P2]

Blocks (1):
  ← fort-c8y.21: Phase 5: Remove legacy mechanisms [P3 - open]


