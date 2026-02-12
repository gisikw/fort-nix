---
id: fort-cy6.6
status: closed
deps: [fort-cy6.1]
links: []
created: 2025-12-27T23:52:19.969746559Z
type: task
priority: 1
parent: fort-cy6
---
# Refactor secrets.nix for editor-only keys

Refactor secrets.nix to use editor-only keys on the main branch, enabling the two-branch secrets model.

## Context
Currently, secrets are keyed for all devices and re-keyed at deploy time. For GitOps, we need:
- **main branch**: secrets keyed for editors only (laptop, ratched, forge)
- **release branch**: CI re-keys for actual host recipients

This separates secret authorship (editors can decrypt on main) from production access (only hosts can decrypt on release).

## Current State
`secrets.nix` currently defines `publicKeys` per-secret, including device keys when `KEYED_FOR_DEVICES=1`.

## Implementation

### Define editor keys
```nix
let
  # Keys that can decrypt secrets on main branch
  editors = [
    clusterManifest.sshPublicKey                    # Laptop (primary deploy key)
    devices."<ratched-uuid>".sshPublicKey           # Dev sandbox
    devices."<drhorrible-uuid>".sshPublicKey        # Forge (needs to re-key)
  ];
in {
  # All secrets use editors only
  "aspects/mesh/auth-key.age".publicKeys = editors;
  "apps/homeassistant/secrets.yaml.age".publicKeys = editors;
  # ... all other secrets
}
```

### Remove KEYED_FOR_DEVICES logic
The deploy-time rekeying with `KEYED_FOR_DEVICES=1` is no longer needed for GitOps hosts. Keep deploy-rs functional for forge (manual deploys), but the release workflow handles rekeying for comin hosts.

### Re-encrypt all secrets
After updating secrets.nix:
```bash
agenix -r  # Re-key all secrets for new recipients
```

### Update .gitignore / pre-commit
Ensure secrets are only committed with editor keys (never device keys on main).

## Acceptance Criteria
- [ ] All secrets in main branch keyed only for editors
- [ ] Laptop can decrypt all secrets
- [ ] Ratched can decrypt all secrets  
- [ ] Forge (drhorrible) can decrypt all secrets
- [ ] Production hosts CANNOT decrypt secrets on main branch
- [ ] deploy-rs still works for forge (manual deploy)

## Dependencies
- fort-cy6.1: Forge's SSH key must be known

## Security Considerations
- This is a security-sensitive change
- Verify editor list is correct before re-keying
- Old commits in git history will still have device-keyed secrets (acceptable)

## Notes
- This is foundational for the release workflow
- Claude Code on ratched gains ability to author/edit secrets
- Claude Code still cannot decrypt production secrets (those only exist on release branch)


