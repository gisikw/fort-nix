---
id: fort-cy6.21
status: closed
deps: []
links: []
created: 2025-12-28T07:21:46.574313228Z
type: task
priority: 3
parent: fort-cy6
---
# Support comin test branches with secret re-keying

## Context

Comin supports a pattern where pushing to a `host-test` branch lets the host pull and run the config without updating the boot generation. This is useful for testing changes before committing to them.

However, with the two-branch secrets model, `main` (and branches off main) are keyed for editors only. Hosts can't decrypt those secrets directly.

## Proposed Solution

Create a workflow that:
1. Watches for pushes to `*-test-rekey` branches (e.g., `minos-test-rekey`)
2. Re-keys secrets for the target host
3. Pushes to the corresponding `*-test` branch (e.g., `minos-test`)

This lets developers push experimental changes to `host-test-rekey` and have CI produce a decryptable `host-test` branch for comin to pull.

## Alternatives Considered

- Could require devs to manually re-key for test deploys (annoying)
- Could have a single `test-rekey` branch that CI fans out to per-host test branches (complex)

## Dependencies
- fort-cy6.7: Release workflow (establishes the re-keying pattern)
- fort-cy6.13: Comin aspect (hosts need comin to use test branches)

## Notes
- Naming TBD: `host-test-rekey` vs `test/host` vs something else
- May want to auto-cleanup stale test branches


