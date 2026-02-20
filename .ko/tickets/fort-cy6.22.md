---
id: fort-cy6.22
status: closed
deps: []
links: []
created: 2025-12-28T08:09:57.615598545Z
type: task
priority: 3
parent: fort-cy6
---
# Consolidate key definitions in cluster manifest

## Context

The cluster manifest has overlapping key definitions that evolved organically:

- `sshKey.publicKey` - primary laptop deploy key
- `authorizedDeployKeys` - additional deploy keys (added to root authorized_keys AND secrets)
- `privilegedKeys` - keys that can decrypt secrets on main branch
- `ciAgeKey` - CI-specific key

## Cleanup Options

1. Merge `sshKey.publicKey` into `privilegedKeys` (already duplicated there)
2. Clarify purpose of `authorizedDeployKeys` vs `privilegedKeys`
3. Consider whether `authorizedDeployKeys` should only affect SSH access, not secret decryption

## Notes
Low priority cleanup after CI/CD pipeline is stable.


