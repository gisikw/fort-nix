---
id: fort-cy6.4
status: closed
deps: [fort-cy6.1]
links: []
created: 2025-12-27T23:50:05.470953583Z
type: task
priority: 2
parent: fort-cy6
---
# Set up Forgejo Actions runner

Configure a Forgejo Actions runner on drhorrible to execute CI workflows.

## Context
Forgejo Actions is GitHub Actions-compatible CI. It requires a runner daemon to execute workflows. The runner will run on drhorrible (forge) alongside Forgejo itself.

## Implementation

### Enable Actions in Forgejo
Update `apps/forgejo/default.nix`:

```nix
services.forgejo.settings = {
  # ... existing settings ...
  actions = {
    ENABLED = true;
  };
};
```

### Configure Runner
Use the NixOS gitea-actions-runner service with forgejo-runner package:

```nix
services.gitea-actions-runner = {
  package = pkgs.forgejo-runner;
  instances.default = {
    enable = true;
    name = "forge-runner";
    url = "https://git.gisi.network";
    tokenFile = config.age.secrets.forgejo-runner-token.path;
    labels = [
      "nixos:host"          # Native NixOS runner
      "x86_64-linux:host"   # Architecture label
    ];
    settings = {
      # Runner settings
      capacity = 2;  # Parallel jobs
    };
  };
};
```

### Secrets
- Create runner registration token via Forgejo admin UI
- Store in `apps/forgejo/runner-token.age`
- Add to agenix configuration

### Nix in Runner Environment
The runner needs Nix available for CI jobs. Options:
1. Use `nixos:host` label and run directly on host (has Nix already)
2. Use container with Nix installed

Option 1 is simpler for our use case since we're building NixOS configs.

### Runner Capabilities
The runner will need:
- Nix with flakes enabled
- Network access to cache.nixos.org and our Attic cache (once set up)
- Ability to run `nix build`, `nix flake check`, etc.

## Acceptance Criteria
- [ ] Runner appears in Forgejo admin → Actions → Runners
- [ ] Runner shows as online
- [ ] Test workflow executes successfully (e.g., simple `nix flake check`)

## Dependencies
- fort-cy6.1: Forgejo must be deployed first

## Notes
- Runner token needs to be generated after Forgejo is running
- Consider adding more runners later for parallelism or different arches
- Docker/Podman not required if using host labels

Labels: [ci forgejo phase-1]


