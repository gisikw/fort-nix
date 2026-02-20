---
id: fort-cy6.15
status: closed
deps: [fort-cy6.13, fort-cy6.10]
links: []
created: 2025-12-27T23:58:46.149670638Z
type: task
priority: 2
parent: fort-cy6
---
# Add post-build cache push hook

Configure hosts to push their builds back to Attic cache after successful deployment.

## Context
For heterogeneous architectures, CI may not be able to build everything. Hosts that build locally should push their results to cache so future builds (on any host of that arch) get cache hits.

## Implementation

### Option A: Comin post-deploy hook
Comin supports post-deploy commands:

```nix
services.comin = {
  # ... existing config ...

  postBuildCommand = '
    ${pkgs.attic-client}/bin/attic push fort-cache "$out"
  ';
};
```

This pushes the built system closure after successful activation.

### Option B: Nix post-build-hook
Global hook for ALL nix builds:

```nix
nix.settings.post-build-hook = pkgs.writeScript "upload-to-cache" '
  #\!/bin/bash
  set -euf

  if [ -n "${OUT_PATHS:-}" ]; then
    echo "Pushing to cache: $OUT_PATHS"
    attic push fort-cache $OUT_PATHS || true
  fi
';
```

### Authentication
Each host needs a push token for Attic. Options:

1. **Shared write token**: All hosts use the same token (simpler)
2. **Per-host tokens**: Each host has its own token (more auditable)

For homelab, Option 1 is fine. Store token in agenix and configure attic client.

### Recommendation
Use Option A (comin hook) for GitOps hosts - only pushes system builds, not every random build.

Keep Option B available as an aspect for hosts that do a lot of local building.

## Acceptance Criteria
- [ ] Hosts can push to Attic cache
- [ ] After comin deploys, built paths appear in cache
- [ ] Subsequent builds on other hosts of same arch get cache hits

## Dependencies
- fort-cy6.13: Comin aspect needed
- fort-cy6.10: Hosts need Attic client configured

## Notes
- This completes the multi-writer cache model
- First ARM host to deploy will populate ARM cache for all ARM hosts
- Monitor cache growth - may need garbage collection tuning


