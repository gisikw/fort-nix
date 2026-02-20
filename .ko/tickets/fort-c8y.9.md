---
id: fort-c8y.9
status: closed
deps: [fort-c8y.8]
links: []
created: 2026-01-08T04:02:22.348111875Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 3: Update capability options schema

Add async mode and trigger options to capabilities.

## New Options

- mode = "rpc" for synchronous (default is async)
- cacheResponse - persist responses for handler to reuse
- triggers.initialize - run on boot
- triggers.systemd - list of units that trigger re-run

## Tasks

- [ ] Add mode option (default async, explicit "rpc" for sync)
- [ ] Add cacheResponse option
- [ ] Add triggers.initialize option
- [ ] Add triggers.systemd option (list of unit names)
- [ ] Remove needsGC and ttl (inferred from mode)
- [ ] Update mandatory capabilities (status, manifest, needs) to mode = "rpc"

## Acceptance Criteria

- Existing RPC capabilities still work
- New options accepted by Nix module
- Default mode is async


