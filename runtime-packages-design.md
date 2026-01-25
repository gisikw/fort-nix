# Runtime-Managed Packages

## The Problem

When I'm iterating on tools locally (scripts, small binaries), I often forget to commit them. The tool works on my machine, but it's not in git, so:
- Other hosts can't use it
- CI doesn't know about it
- If I lose the machine, I lose the work

I want a deployment path where **the only way to deploy is through git**. If it's not committed and pushed, it doesn't run anywhere.

## Why Not Just nixos-rebuild?

Too heavyweight for small tools. I want to iterate on a CLI, push, and have it deploy in seconds — not rebuild the whole system config.

## Solution Overview

Leverage the existing control plane needs/capabilities pattern:

1. **Hosts declare subscriptions** — "I want `wicket` from repo X"
2. **CI builds and caches** — pushes to attic, records the store path
3. **CI triggers refresh** — tells the provider "re-deliver to subscribers"
4. **Provider re-delivers** — sends new rev/store path to subscribed hosts
5. **Host handler** — realizes the store path, symlinks into `/run/managed-bin/`

No webhooks to individual hosts. No SSH. Just the control plane doing what it already does, plus a new `refresh` primitive.

---

## New Control Plane Primitive: `refresh`

### The Gap

Currently, the control plane is consumer-driven:
- Consumer asks for need → provider responds
- Nag timer re-asks if unsatisfied
- `force-nag` makes consumers re-ask

There's no way to tell a provider "your source data changed, re-deliver."

### The Primitive

A new mandatory capability on all hosts:

```
fort <host> refresh '{"capability": "<name>"}'
```

Behavior:
1. Provider looks up all current subscriptions for that capability
2. Re-invokes the handler with current state
3. Sends callbacks to all subscribers with (potentially updated) responses

This is the missing piece between "consumer asks" and "provider pushes."

### Implementation Sketch

```nix
# In common/fort/control-plane.nix, alongside force-nag

refresh = pkgs.writeShellScript "handler-refresh" ''
  capability=$(echo "$request" | jq -r '.capability // empty')

  if [ -z "$capability" ]; then
    echo '{"error": "capability required"}' >&2
    exit 1
  fi

  # Check if we provide this capability
  if ! grep -q "\"$capability\"" /etc/fort/capabilities.json; then
    echo '{"error": "not a provider for this capability"}' >&2
    exit 1
  fi

  # Re-run the provider's fulfillment cycle for this capability
  # This reads provider state, re-invokes handler, sends callbacks for deltas
  /run/current-system/sw/bin/fort-provider --refresh "$capability"

  echo '{"status": "refreshed", "capability": "'"$capability"'"}'
'';
```

### RBAC

Restricted to principals that should be able to trigger deploys:
- `forge` principal (for CI-triggered refreshes)
- `dev-sandbox` principal (for manual testing)

---

## Runtime Package Provider (Forgejo)

### Capability Declaration

Add to `apps/forgejo/default.nix`:

```nix
fort.host.capabilities.runtime-package = {
  mode = "async";
  handler = ./handlers/runtime-package.sh;
  # No systemd triggers - we use explicit refresh calls from CI
};
```

### Provider State

Forgejo tracks subscriptions in `/var/lib/fort/provider-state.json`:

```json
{
  "runtime-package": {
    "joker:runtime-package:wicket": {
      "request": {
        "repo": "infra/wicket",
        "constraint": "main"
      },
      "response": {
        "repo": "infra/wicket",
        "rev": "abc1234",
        "storePath": "/nix/store/...-wicket-1.0.0"
      },
      "updated_at": 1704672005
    }
  }
}
```

### Handler Logic

Provider handlers are written in Go (not bash). The handler would:

1. Parse request for `repo` and `constraint`
2. Query forgejo API for latest successful workflow run on that branch
3. Look up the store path (via attic metadata, workflow artifact, or convention)
4. Return `{repo, rev, storePath}` to consumer

The exact mechanism for mapping rev → store path depends on how we tag artifacts in attic. Could be:
- Attic tags/metadata
- A convention in the workflow (write store path to a known location)
- Query the nix store for a specific `name-rev` pattern

### Where Does the Handler Get Build Info?

The handler queries forgejo directly — no separate manifest needed. Options:

1. **Forgejo API** — query latest successful workflow run for repo+branch, extract artifact info
2. **Attic metadata** — query the cache for latest store path tagged with repo+ref
3. **Git tags** — CI tags successful builds, handler resolves tag to rev and derives store path

The handler already runs on the forgejo host, so it has direct access to forgejo's database/API.

---

## Consumer Side

### Host Declaration

In `clusters/<cluster>/hosts/<name>/manifest.nix`:

```nix
{
  fort.host.runtimePackages = [
    { repo = "infra/bz"; }
    { repo = "infra/my-tool"; constraint = "release"; }
  ];
}
```

### Module Implementation

New module at `common/runtime-packages.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.fort.host.runtimePackages;

  # Generate needs from declared packages
  packageNeeds = map (pkg: {
    name = "runtime-package:${pkg.repo}";
    provider = config.cluster.forge.host;  # e.g., "drhorrible"
    request = {
      repo = pkg.repo;
      constraint = pkg.constraint or "main";
    };
    handler = pkgs.writeShellScript "handle-runtime-package" ''
      store_path=$(echo "$response" | jq -r '.storePath')

      # Realize the store path (pulls from attic if not local)
      nix store realize "$store_path"

      # Symlink everything from bin/ into /run/managed-bin/
      mkdir -p /run/managed-bin
      for bin in "$store_path"/bin/*; do
        [ -e "$bin" ] && ln -sf "$bin" /run/managed-bin/
      done

      echo "Deployed $(ls "$store_path/bin/" | tr '\n' ' ')"
    '';
  }) cfg;

in {
  options.fort.host.runtimePackages = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        repo = lib.mkOption { type = lib.types.str; };
        constraint = lib.mkOption {
          type = lib.types.str;
          default = "main";
        };
      };
    });
    default = [];
  };

  config = lib.mkIf (cfg != []) {
    # Add needs for each package
    fort.host.needs = packageNeeds;

    # Ensure /run/managed-bin is in PATH
    environment.sessionVariables.PATH = [ "/run/managed-bin" ];

    # Alternative: add to system path
    environment.extraInit = ''
      export PATH="/run/managed-bin:$PATH"
    '';
  };
}
```

---

## CI Integration

### Forgejo Actions Workflow

In each runtime-deployable repo, add `.forgejo/workflows/deploy.yml`:

```yaml
name: Build and Deploy

on:
  push:
    branches: [main, release]

jobs:
  build:
    runs-on: nix
    steps:
      - uses: actions/checkout@v4

      - name: Build
        run: nix build .#default

      - name: Push to Attic
        run: attic push forge ./result

      - name: Trigger Refresh
        run: |
          # Tell forgejo to re-deliver to all runtime-package subscribers
          # Handler will query forgejo API for latest build info
          fort drhorrible refresh '{"capability": "runtime-package"}'
```

That's it. The handler does the work of looking up what the latest build is.

---

## Flow Summary

```
Developer                 Forgejo CI              Forgejo Host           Consumer Host
    |                         |                        |                       |
    | git push                |                        |                       |
    |------------------------>|                        |                       |
    |                         | nix build              |                       |
    |                         | attic push             |                       |
    |                         |                        |                       |
    |                         | fort drhorrible        |                       |
    |                         |   refresh {cap: "..."}|                       |
    |                         |----------------------->| query own API for     |
    |                         |                        | latest build info     |
    |                         |                        |                       |
    |                         |                        | for each subscriber   |
    |                         |                        |---------------------->|
    |                         |                        |   callback: new rev   |
    |                         |                        |                       |
    |                         |                        |                       | handler runs:
    |                         |                        |                       |   nix store realize
    |                         |                        |                       |   symlink to /run/managed-bin
    |                         |                        |                       |
```

---

## Implementation Phases

### Phase 1: `refresh` Primitive
- Add `refresh` handler to mandatory capabilities
- Implement `fort-provider --refresh <capability>` logic
- Wire up RBAC for `forge` and `dev-sandbox` principals
- Test with existing capability (e.g., manually refresh `oidc-register`)

### Phase 2: Provider Capability
- Add `runtime-package` capability to forgejo
- Handler queries forgejo API for latest successful build per repo
- Implement provider state tracking for async capabilities
- Test handler with manual requests

### Phase 3: Consumer Module
- Create `common/runtime-packages.nix`
- Wire up `/run/managed-bin` PATH integration
- Add to a test host with a simple package subscription
- Test end-to-end with manual `refresh` call

### Phase 4: CI Integration
- Add workflow template to bz repo
- Verify attic push works from CI
- Verify `refresh` call works from CI runner
- Document the pattern for other repos

### Phase 5: Polish
- Add monitoring/alerting for failed deliveries
- Consider rollback mechanism (keep N previous versions?)
- Document in AGENTS.md

---

## First Consumer

`bz` — a small tool that iterates frequently and would benefit from push-to-deploy.

---

## Open Questions

1. **Rollback** — Should we keep previous versions and allow rollback?
2. **Failure handling** — What happens if `nix store realize` fails (attic down, store path missing)?
3. **Provider state bootstrapping** — On first subscription, provider has no build info yet. Return error or empty response?
