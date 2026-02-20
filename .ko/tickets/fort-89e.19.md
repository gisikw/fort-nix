---
id: fort-89e.19
status: closed
deps: [fort-89e.8, fort-89e.14, fort-89e.17, fort-89e.18]
links: []
created: 2025-12-30T22:06:08.611599466Z
type: task
priority: 2
parent: fort-89e
---
# Remove service-registry aspect

After all functionality migrated to control plane:

1. Verify all consumers working via new system:
   - OIDC registration ✓
   - Proxy configuration ✓
   - DNS updates ✓
2. Remove aspects/service-registry/ entirely
3. Remove registry.rb and related systemd units
4. Clean up any references in host manifests

This is the 'flip the switch' moment for the control plane.

## Acceptance Criteria

- service-registry aspect deleted
- No regressions in OIDC, proxy, or DNS functionality
- All coordination happens via agent calls


