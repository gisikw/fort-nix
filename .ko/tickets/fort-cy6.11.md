---
id: fort-cy6.11
status: closed
deps: [fort-cy6.9, fort-cy6.7]
links: []
created: 2025-12-27T23:55:18.201841246Z
type: task
priority: 2
parent: fort-cy6
---
# Configure CI runner to use Attic cache

Configure the Forgejo Actions runner to both pull from and push to the Attic binary cache.

## Context
The CI runner is the ideal place to warm the cache. Every `nix flake check` run:
1. Evaluates all host configurations
2. Builds derivations (with `--no-build` we skip this, but release builds will)
3. Should pull from our cache first (avoid hammering cache.nixos.org)
4. Should push new builds back to cache

## Implementation

### 1. Configure Nix substituters
The forge host already gets this from cy6.10 common config, but verify the runner inherits it.

### 2. Add post-build hook for cache push
In the forgejo app module, add a post-build hook that pushes to Attic.

### 3. Configure Attic credentials for runner
The runner needs a push token stored in agenix.

### 4. Add attic-client to runner PATH
Update the runner config.yml PATH to include attic-client.

## Acceptance Criteria
- [ ] CI pulls from Attic cache (check logs for cache hits)
- [ ] CI pushes successful builds to Attic
- [ ] Subsequent CI runs show improved cache hit rate
- [ ] cache.nixos.org requests reduced

## Dependencies
- fort-cy6.9: Attic must be deployed
- fort-cy6.5: CI workflow must exist

## Notes
- The post-build hook runs for ALL nix builds on forge, not just CI
- This is actually desirable - any build on forge warms the cache


