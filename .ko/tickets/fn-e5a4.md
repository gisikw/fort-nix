---
id: fn-e5a4
status: closed
deps: []
created: 2026-03-28T03:54:18Z
type: task
priority: 2
---
# Validate sops-nix with grafana-admin-pass

Proof-of-concept: migrate one agenix secret to sops-nix, running both systems side by side.

## Target secret

apps/fort-observability/grafana-admin-pass.age — single host, low impact, simple password value.

## Scope

1. Add sops-nix as a flake input (alongside agenix, not replacing)
2. Create .sops.yaml with a creation rule for the grafana secret
3. Encrypt the same value with sops
4. Update the grafana module to read from sops.secrets instead of age.secrets
5. Deploy to the grafana host, verify decryption + service starts
6. Document: what worked, what was annoying, any gotchas

## Success criteria

- Grafana starts with the sops-managed secret
- Both sops and agenix coexist without conflict
- Clear recommendation on whether to proceed with full migration

## Context

Part of a broader secrets architecture review. Current agenix setup relies on CI rekeying (release.yml lines 109-284) to derive per-host recipients from flake eval. Exploring whether sops-nix eliminates that pipeline. See also fn-66f9 (automated rekey).
