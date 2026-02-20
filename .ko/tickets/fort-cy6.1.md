---
id: fort-cy6.1
status: closed
deps: []
links: []
created: 2025-12-27T23:49:13.162017945Z
type: task
priority: 2
parent: fort-cy6
---
# Add Forgejo app to forge role

Create a Forgejo app module and add it to the forge role on drhorrible.

## Context
Forgejo is a self-hosted git forge (Gitea fork) that will serve as our CI/CD hub. It runs on drhorrible alongside existing forge services (CoreDNS, Zot, Prometheus/Grafana/Loki).

## Implementation

### Create the app module
Create `apps/forgejo/default.nix`:

```nix
{ config, lib, pkgs, ... }:
let
  cfg = config.fort;
  domain = cfg.clusterManifest.domain;
in {
  services.forgejo = {
    enable = true;
    database.type = "sqlite3";
    settings = {
      server = {
        DOMAIN = "git.${domain}";
        ROOT_URL = "https://git.${domain}/";
        HTTP_PORT = 3001;  # Avoid conflict with Grafana on 3000
      };
      service = {
        DISABLE_REGISTRATION = true;  # SSO only
      };
      # Session/security settings TBD based on SSO integration
    };
  };

  # Expose via fortCluster.exposedServices
  fort.exposedServices.forgejo = {
    port = 3001;
    subdomain = "git";
    visibility = "vpn";  # or "public" if needed externally
    sso = "oidc";  # integrate with pocket-id
  };
}
```

### Add to forge role
Update `roles/forge.nix` to include forgejo in the apps list.

### Persistence
Forgejo data should persist at `/persist/system/var/lib/forgejo` (impermanence pattern).

## Acceptance Criteria
- [ ] Forgejo service starts on drhorrible
- [ ] Web UI accessible at git.fort.gisi.network (via mesh)
- [ ] Data persists across reboots

## Notes
- SSO configuration will be handled in a follow-up ticket
- Runner setup is also a separate ticket


