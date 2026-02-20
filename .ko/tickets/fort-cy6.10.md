---
id: fort-cy6.10
status: closed
deps: [fort-cy6.9]
links: []
created: 2025-12-27T23:54:29.467595091Z
type: task
priority: 2
parent: fort-cy6
---
# Configure hosts to use Attic cache

Configure all hosts to substitute from the Attic binary cache.

## Context
With Attic running on forge, all hosts should be configured to pull pre-built derivations from the cache instead of building locally.

**Critical for CI**: The Forgejo runner is the primary cache consumer AND producer. When CI runs `nix flake check`, it:
1. Pulls existing derivations from cache (avoids hammering cache.nixos.org)
2. Builds anything missing
3. Pushes new builds back to cache

This means CI naturally warms the cache - a separate "build for cache" step is unnecessary.

## Implementation

### Create shared cache configuration
Add to common configuration (e.g., in `common/host.nix` or a new aspect):

```nix
{ config, lib, pkgs, ... }:
let
  cfg = config.fort;
  domain = cfg.clusterManifest.domain;
in {
  nix.settings = {
    substituters = [
      "https://cache.nixos.org"
      "https://cache.${domain}"
    ];
    
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "cache.${domain}-1:XXXXX..."  # Replace with actual key from fort-cy6.9
    ];
    
    trusted-users = [ "root" "@wheel" ];
  };
}
```

### CI Runner Configuration
The forge host runs the CI runner, so it gets cache config automatically. Additionally, configure the runner's nix to push builds:

```nix
# In forgejo app or forge role
nix.settings.post-build-hook = pkgs.writeScript "upload-to-cache" ''
  #!${pkgs.bash}/bin/bash
  set -euf
  if [ -n "${OUT_PATHS:-}" ]; then
    ${pkgs.attic-client}/bin/attic push fort-cache $OUT_PATHS
  fi
'';
```

This makes every CI build automatically populate the cache.

### Push capability for other hosts
For the multi-writer model, hosts also need push tokens (stored in agenix).

## Acceptance Criteria
- [ ] All hosts have cache.gisi.network in substituters
- [ ] CI runner pulls from cache (verify cache hits in logs)
- [ ] CI runner pushes builds to cache (post-build hook)
- [ ] Subsequent CI runs are faster due to cache hits

## Dependencies
- fort-cy6.9: Attic must be deployed and cache created

## Notes
- The public key will be known after Attic setup
- CI becomes the primary cache warmer - no separate build job needed
- Monitor cache hit rates via Attic metrics


