# CI/CD and GitOps Recommendation for Fort-Nix

## Current State Summary

The `fort-nix` repo is already quite sophisticated:
- **8 hosts** in the `bedlam` cluster with a clean device → host → role/app/aspect composition model
- **Manual deployment** via `just deploy <hostname>` using deploy-rs
- **Secrets** managed with agenix, decrypted at deploy time using a deployer SSH key
- **drhorrible** already serves as "forge" with CoreDNS, Zot registry, Prometheus/Grafana/Loki
- **ratched** is the dev sandbox where Claude Code runs

## The Core Problem

We want Claude Code on `ratched` to be able to:
- Read and write secrets (someone has to author them)
- Push changes that trigger deployments
- Run CI checks

Without having:
- Root SSH access to production hosts
- The ability to decrypt production secrets (only editor-keyed versions)

---

## Recommended Path: Forgejo + Comin (Hybrid)

Given the existing infrastructure, a **two-phase approach** is recommended:

### Phase 1: Add Forgejo to the forge (drhorrible)

Forgejo is a drop-in addition to the stack that provides:
- Self-hosted git with web UI
- Forgejo Actions (GitHub Actions compatible) for CI
- Native NixOS module (`services.forgejo`) - low maintenance

```nix
# apps/forgejo/default.nix
services.forgejo = {
  enable = true;
  settings.server.DOMAIN = "git.${domain}";
  # SSO via pocket-id (existing OIDC provider)
};
```

This runs alongside the existing git remote - can mirror or migrate gradually.

### Phase 2: Add Comin for pull-based GitOps

[Comin](https://github.com/nlewo/comin) is purpose-built for this exact use case:
- Each host polls the git repo and deploys its own config
- No central deployer with root access everywhere needed
- Claude Code pushes commits → hosts self-deploy
- Testing branch support for safe experimentation

```nix
# aspects/gitops/default.nix
services.comin = {
  enable = true;
  remotes = [{
    name = "origin";
    url = "https://git.fort.gisi.network/infra/fort-nix.git";
    branches.main.name = "main";
  }];
};
```

### How This Solves the Problem

| Actor | Can Do | Cannot Do |
|-------|--------|-----------|
| Claude Code (ratched) | Push to git repo, trigger CI checks | Decrypt secrets, SSH to other hosts |
| Forgejo Actions | Run `nix flake check`, build closures | Deploy (optional - can delegate to comin) |
| Comin (per-host) | Pull changes, activate own system | Affect other hosts |

The key insight: **secrets stay encrypted in the repo**. Each host has its own agenix key that decrypts only what it needs during `nixos-rebuild switch`. Claude Code never touches the decrypt keys.

---

## Secrets Architecture: Two-Branch Model

The current deploy-time rekeying doesn't translate directly to pull-based GitOps. Here's a refined model:

### The Problem

Current (push-based):
```
main branch: secrets keyed for [laptop, all devices...]
             ↓ (at deploy time)
deployer re-keys with KEYED_FOR_DEVICES=1
             ↓
deploy-rs pushes, agenix delivers only what's needed
```

Naive pull-based would require all hosts to decrypt everything (bad).

### The Solution: Editor-Keyed Main + CI-Rekeyed Release

```
main branch: secrets keyed for [editors: laptop, ratched, forge]
             ↓ (CI job on push to main)
forge inspects config, re-keys per-host based on what agenix would deploy
             ↓
release branch: secrets keyed for actual recipients only
             ↓
comin pulls from release, each host decrypts only its own
```

### secrets.nix Structure

```nix
let
  # Editor keys - can decrypt anything on main branch
  editors = [
    clusterManifest.sshPublicKey        # laptop
    devices.ratched.sshPublicKey        # devbox
    devices.drhorrible.sshPublicKey     # forge (needs to re-key)
  ];

  # On main branch, all secrets use editors
  # CI job will re-key for actual recipients on release branch
in {
  "aspects/mesh/auth-key.age".publicKeys = editors;
  "apps/homeassistant/secrets.yaml.age".publicKeys = editors;
  # ...
}
```

### Forge CI Workflow (`.forgejo/workflows/release.yml`)

```yaml
on:
  push:
    branches: [main]

jobs:
  rekey-and-release:
    steps:
      - uses: actions/checkout@v4

      - name: Determine per-host secrets
        run: |
          for host in $(nix eval .#hosts --json | jq -r 'keys[]'); do
            nix eval ".#nixosConfigurations.$host.config.age.secrets" --json \
              | jq -r 'keys[]' > /tmp/secrets-$host.txt
          done

      - name: Re-key secrets for recipients
        env:
          FORGE_KEY: ${{ secrets.FORGE_AGE_KEY }}
        run: |
          for host in $(nix eval .#hosts --json | jq -r 'keys[]'); do
            hostKey=$(nix eval ".#hosts.$host.device.sshPublicKey" --raw)
            for secret in $(cat /tmp/secrets-$host.txt); do
              agenix -r -i "$FORGE_KEY" -k "$hostKey" "$secret"
            done
          done

      - name: Push to release branch
        run: |
          git checkout -B release
          git add -A
          git commit -m "Re-keyed secrets for $(git rev-parse --short main)"
          git push -f origin release
```

### Comin Configuration

```nix
services.comin = {
  enable = true;
  remotes = [{
    name = "origin";
    url = "https://git.fort.gisi.network/infra/fort-nix.git";
    branches.main.name = "release";  # Pull from release, not main
  }];
};
```

### Exception: Forge Stays Manual

Forge (drhorrible) should NOT run comin. It's critical infrastructure - if it auto-deploys a broken config, you lose:
- Forgejo (can't push fixes)
- Attic (can't substitute builds)
- CoreDNS (mesh DNS breaks)
- The CI/CD pipeline itself

Chicken-and-egg. Keep forge on manual deploy-rs (or direct `nixos-rebuild switch`).

### Benefits of This Model

| Concern | Solution |
|---------|----------|
| Claude Code can author secrets | Yes - has editor key for main branch |
| Claude Code can't decrypt prod secrets | Correct - prod keys only on release branch |
| No master deploy key | Forge only has its own key + re-key capability |
| Git history churn | Minimal - main branch secrets don't change recipients |
| Derivable from config | Preserved - CI inspects agenix config to determine recipients |

---

## On Rollbacks and Safety

### What deploy-rs Magic Rollback Covers

- Activation broke SSH → automatic revert before lockout

### What It Doesn't Cover

- Boot failures (kernel panic, initrd issues)
- Network config that breaks mesh (can't SSH even if host is up)
- Services that start but misbehave

### Comin's Safety Features

- **Testing branch**: Deploys with `nixos-rebuild test` (no bootloader update)
- If testing fails, main is unaffected
- Can validate changes before merging to main

### Recommendation

- Use comin for day-to-day deployments (most changes are low-risk)
- Keep deploy-rs available for high-risk changes where you want the safety net
- Treat boot-level recovery as a separate concern (BIOS/bootloader injection, serial console, etc.)

The reality: deploy-rs rollback is nice-to-have but covers a narrow failure mode. If you're nervous about a change, use the testing branch workflow or do a manual deploy-rs deploy.

---

## Binary Cache: Attic

### Why Cache?

Without caching, each host builds its own derivations on `nixos-rebuild switch`. With caching:
- Build once, distribute everywhere
- Faster deploys (download vs compile)
- Reduced load on smaller devices (future RPis, etc.)

### Architecture: Multi-Writer Cache

```
Forge CI builds x86_64-linux hosts → pushes to Attic
                ↓
Hosts pull from cache (substituters)
                ↓
Cache miss? Build locally → push result to Attic
                ↓
Future builds (any host, any arch) → cache hit
```

All hosts can read AND write. This handles heterogeneous architectures gracefully - forge builds what it can (x86_64), other architectures build on-target and contribute back.

### Why Multi-Writer is Safe

Nix store paths are content-addressed: `/nix/store/<hash>-foo` where the hash is derived from all build inputs. A compromised host cannot poison the cache for legitimate paths because:

- Different build → different hash → different store path
- You can't substitute malicious content under a legitimate path's hash
- Signatures add attestation but content-addressing is the primary guarantee

The theoretical attack (impure build with same hash, different content) requires compromising the build environment in ways that don't affect the input hash - practically impossible for pure NixOS builds. Solar flare bitflips are a more realistic concern.

### Attic Configuration

```nix
# Add to forge role or as apps/attic/default.nix
services.attic = {
  enable = true;
  # ...
};
```

On all hosts:

```nix
nix.settings = {
  substituters = [ "https://cache.fort.gisi.network" ];
  trusted-public-keys = [
    "fort-cache:XXXXX..."  # forge's key
    # Future: add keys for other arches as needed
  ];
};
```

### CI Integration

The release workflow gains a build step. Forge attempts all hosts (including non-native arches via cross-compilation or QEMU binfmt) and treats failures as non-fatal:

```yaml
jobs:
  build-and-release:
    steps:
      - name: Build all hosts (best-effort)
        run: |
          for host in $(nix eval .#hosts --json | jq -r 'keys[]'); do
            nix build ".#nixosConfigurations.$host.config.system.build.toplevel" \
              -o "result-$host" || echo "::warning::Failed to build $host, will build on-target"
          done

      - name: Push successful builds to cache
        run: attic push fort-cache ./result-* 2>/dev/null || true

      # ... existing re-key and release steps
```

Whatever forge can build gets cached. Whatever fails builds on-target and gets pushed back via the post-deploy hook.

### Comin Post-Deploy Hook

Hosts push their builds after successful activation:

```nix
services.comin = {
  # ...
  postBuildCommand = ''
    attic push fort-cache "$out"
  '';
};
```

This way, an RPi that builds aarch64 packages contributes them back - next aarch64 host gets cache hits.

---

## Why Not Vault?

| Concern | Vault | Branch-based agenix |
|---------|-------|---------------------|
| Runtime dependency | Yes - services can't start if Vault down | No - secrets baked at deploy |
| Complexity | High - policies, tokens, renewal | Medium - one CI job |
| Audit trail | Excellent | Git history |
| Offline boot | Broken | Works |
| Fits Nix philosophy | Poorly (imperative) | Well (declarative) |

Vault makes sense for dynamic secrets in microservices. For static config secrets in a homelab, it adds critical runtime dependency without proportionate benefit.

---

## Alternative Options Considered

### Hercules CI
- Pro: Nix-native, shared build cache
- Con: Either $$ SaaS or self-hosted agent complexity
- Verdict: Overkill for homelab scale

### Hydra
- Pro: Official NixOS CI
- Con: Complex to set up, heavy resource usage, NixOS-only host
- Verdict: Better for distro-scale builds, not deployment

### Pure Forgejo Actions (push-based deploy)
- Pro: Familiar GitHub Actions workflow
- Con: Runner needs deploy credentials (defeats the purpose)
- Verdict: Fine for CI, but comin better for deployment

---

## Suggested Implementation Order

### Phase 1: Forgejo Setup
1. **Add Forgejo app** to drhorrible (forge role)
2. **Configure SSO** via pocket-id for authentication
3. **Mirror/migrate** fort-nix repo to Forgejo
4. **Set up Forgejo runner** on drhorrible

### Phase 2: CI Pipeline
5. **Create `.forgejo/workflows/check.yml`** - runs `nix flake check` on PRs
6. **Refactor `secrets.nix`** - change to editor-only keys on main branch
7. **Create `.forgejo/workflows/release.yml`** - re-keys secrets, pushes to release branch
8. **Test the pipeline** - verify release branch has correctly keyed secrets

### Phase 3: Binary Cache
9. **Add Attic** to forge role (or as standalone app)
10. **Configure all hosts** with substituters + trusted-public-keys
11. **Update release workflow** to build all hosts (best-effort) and push to cache
12. **Test cache flow** - verify hosts substitute from cache instead of building

### Phase 4: GitOps Deployment
13. **Add comin aspect** - start with ratched (low risk, can iterate)
14. **Configure comin** to pull from release branch
15. **Add post-build hook** to push successful builds to cache (for non-x86 arches)
16. **Test end-to-end** - push to main → CI builds + re-keys → release updated → ratched pulls from cache and deploys
17. **Roll out comin** to other hosts incrementally (EXCEPT forge - stays on manual deploy-rs)

### Phase 5: Cleanup
18. **Grant Claude Code** Forgejo push access (no SSH keys, no deploy credentials)
19. **Document manual deploy-rs workflow** for high-risk changes
20. **Keep deploy-rs available** as escape hatch

This approach:
- Builds on existing infrastructure
- Keeps deploy-rs as safety net for risky changes
- Separates CI (Forgejo Actions) from CD (comin)
- Cleanly separates editor privileges from production access

---

## Sources

- [Forgejo - Official NixOS Wiki](https://wiki.nixos.org/wiki/Forgejo)
- [Comin: GitOps for NixOS Machines](https://github.com/nlewo/comin)
- [Attic: Self-hostable Nix Binary Cache](https://github.com/zhaofengli/attic)
- [Building and deploying NixOS systems with Forgejo Actions](https://gradient.moe/blog/2025-09-08-building-nixos-forgejo-actions/)
- [NixOS CI discussion](https://discourse.nixos.org/t/nix-ci-besides-hydra-and-hercules/14353)
- [Hercules CI](https://hercules-ci.com/)
