---
id: fort-0rj
status: open
deps: []
links: []
created: 2025-12-28T03:27:02.216830613Z
type: feature
priority: 3
---
# Support group-based OIDC client restrictions in pocket-id

## Context
Pocket-id supports restricting OIDC client access to specific LDAP groups. This is cleaner than app-level enforcement (e.g., Forgejo's `--required-claim-*`) because:

- Centralized policy: "who can access what" lives in one place
- Apps stay simple - just "use OIDC", no group logic
- Consistent enforcement across all services

## Implementation
Extend `service-registry` to configure group restrictions when creating OIDC clients in pocket-id.

Could leverage the existing `sso.groups` option in `fortCluster.exposedServices`:
```nix
sso = {
  mode = "oidc";
  groups = [ "admin" ];  # Currently only used for oauth2-proxy
};
```

The registry.rb `create_pocketid_client` function would need to pass allowed groups in the API request.

## Notes
- Need to verify pocket-id API supports this (UI shows the option)
- Once implemented, can remove app-level group checks (e.g., Forgejo's `--required-claim-*`)
- Defense-in-depth: could keep app-level as fallback initially


