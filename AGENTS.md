# Repository Guidelines

## Project Structure & Module Organization
- `flake.nix` pins upstream inputs and exposes CLI packages (`agenix`, `nixos-anywhere`, `nixfmt`, `deploy-rs`); keep new inputs minimal.
- `common/` defines shared device and host modules; extend these before editing generated flakes.
- Declarative layers live under `device-profiles/`, `devices/<uuid>/`, and `hosts/<name>/manifest.nix`; keep host-specific options inside manifests, reusable logic in `apps/`, `aspects/`, and `roles/`.
- Secrets and age-encrypted material stay in `secrets.nix`; never commit plaintext keys.
- Expose HTTP services through `fortCluster.exposedServices` so TLS, DNS, and nginx are managed centrally; augment the generated vhost from app modules only when custom locations or headers are required.
- Containerized apps should pull from the on-cluster registry exposed by `apps/zot` (`containers.${domain}`); avoid upstream DockerHub/GHCR URLs so images stay cached.

## Build, Test, and Development Commands
- `just provision <profile> <ip>` fingerprints hardware, scaffolds `devices/<uuid>` and bootstraps the target.
- `just assign <device> <host>` creates `hosts/<host>` with a manifest tied to the device UUID.
- `just deploy <host> [ip]` runs agenix rekeying and deploy-rs for the host (omit `ip` after the node is on the mesh).
- `just fmt` executes `nix run .#nixfmt` to format the repo; run before every commit.

## Coding Style & Naming Conventions
- Write Nix expressions with two-space indentation, trailing commas, and attribute sets ordered for readability.
- Keep host, role, and aspect names lowercase with hyphens (`wifi-access`, `home-assistant`); match directory names to the logical identifier.
- Use `nixfmt` (via `just fmt`) as the source of truth; avoid manual alignment that will fight the formatter.

## Secrets & Access Tips
- Use `just age <path>` to regenerate age-encrypted files; never edit ciphertext directly.
- Keep SSH access synchronized with `~/.ssh/fort`; verify keys before provisioning to avoid stalled jobs.

# ExecPlans
 
When writing complex features or significant refactors, use an ExecPlan (as described in .agent/PLANS.md) from design to implementation.
