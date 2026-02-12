---
id: fort-cy6.13
status: closed
deps: [fort-cy6.12]
links: []
created: 2025-12-27T23:56:13.512683383Z
type: task
priority: 2
parent: fort-cy6
---
# Create comin GitOps aspect

Create a comin aspect for pull-based GitOps deployment.

## Context
Comin is a NixOS deployment tool that operates in pull mode - hosts poll a git repo and deploy their own configuration. This eliminates the need for a central deployer with SSH access to all hosts.

## Implementation

### Add comin to flake inputs
Update root `flake.nix`:

```nix
{
  inputs = {
    # ... existing inputs ...
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  
  outputs = { self, nixpkgs, comin, ... }: {
    # ... existing outputs ...
  };
}
```

### Create aspect
Create `aspects/gitops/default.nix`:

```nix
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.fort;
  domain = cfg.clusterManifest.domain;
in {
  imports = [ inputs.comin.nixosModules.comin ];

  services.comin = {
    enable = true;
    
    remotes = [{
      name = "origin";
      url = "https://git.${domain}/infra/fort-nix.git";
      
      branches.main = {
        name = "release";  # Pull from release branch, not main
      };
      
      # Optional: testing branch for safe experimentation
      # branches.testing = {
      #   name = "testing";
      # };
    }];
    
    # Poll interval
    # interval = 60;  # seconds, default is 60
    
    # Machine identification
    # By default, uses hostname to find its config
  };
}
```

### Flake structure for comin
Comin expects `nixosConfigurations.<hostname>` at the flake root or a specified path. Our current structure has configs in host subflakes. Options:

1. **Export from root flake**: Add `nixosConfigurations` to root flake that re-exports from host flakes
2. **Configure comin path**: Point comin to the host-specific flake

Option 1 is cleaner for comin:

```nix
# In root flake.nix
outputs = { ... }: {
  nixosConfigurations = {
    ratched = (import ./clusters/bedlam/hosts/ratched/flake.nix).nixosConfigurations.ratched;
    # ... other hosts
  };
};
```

### Authentication
Comin needs to fetch from Forgejo. Options:
- Public read access to release branch
- Deploy key with read-only access
- Token-based authentication

For simplicity, consider making the release branch publicly readable (contains no secrets that hosts can't decrypt anyway).

## Acceptance Criteria
- [ ] Comin aspect module created
- [ ] Can be added to host manifest
- [ ] Comin service starts without errors
- [ ] Comin can fetch from Forgejo (may need auth setup)

## Dependencies
- fort-cy6.12: Cache should be working first

## Notes
- Start with ratched (dev sandbox) for testing
- Do NOT add to forge (drhorrible) - it stays on manual deploy
- See recommendation.md for full rationale


