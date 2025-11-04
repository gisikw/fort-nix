# Decouple Cluster Layout for Fort Deployments

This ExecPlan must be maintained in accordance with .agent/PLANS.md. It is self-contained and assumes no knowledge beyond the current repository state.

## Purpose / Big Picture

The Fort infrastructure repository currently assumes a single cluster, with device manifests, host manifests, and deployment secrets all rooted at the top level. After this change an operator will be able to maintain multiple clusters side-by-side, switch between them using a `CLUSTER` environment variable or a `.cluster` file, and run provisioning and deploy commands without rewriting paths. Deployments will continue working throughout the migration because we will introduce cluster-aware shims before relocating any configuration.

- [x] (2025-11-03 19:10Z) ExecPlan authored; stakeholder feedback incorporated.
- [x] (2025-11-03 19:45Z) Stage 1 implemented: `just test` runs flake checks for the root and cluster-scoped hosts/devices; validation blocked in sandbox due to missing Nix daemon socket, needs confirmation on a full Nix host.
- [x] (2025-11-03 21:55Z) Stage 2 implemented: cluster context helper added, `.cluster.example` introduced, and root manifest delegates through the helper while falling back to legacy layout when cluster manifests are absent.
- [x] (2025-11-03 22:20Z) Stage 3 implemented: `clusters/bedlam/manifest.nix` created with expanded key metadata and compatibility shims; root fallback manifest mirrors the new structure.
- [x] (2025-11-03 22:45Z) Stage 4 implemented: `common/host.nix` and `common/device.nix` consume cluster context, expose cluster metadata in `config.fort`, and thread the cluster handle into app/aspect modules for future use.
- [x] (2025-11-03 23:05Z) Stage 5 implemented: `secrets.nix` sources device keys from the active cluster directory and respects the new SSH metadata while preserving legacy fallbacks.
- [x] (2025-11-03 23:25Z) Stage 6 implemented: Just recipes pull cluster settings via `manifest.nix`, honour per-cluster SSH keys, and scaffold/read host and device flakes from cluster-aware paths with migration fallbacks.

## Surprises & Discoveries

- Observation: CLI automation hard-codes the deploy SSH key path `~/.ssh/fort`, which will break once clusters carry different keys. Evidence: `Justfile` defines `ssh := "ssh -i ~/.ssh/fort -o StrictHostKeyChecking=no"`.
- Observation: The Codex sandbox lacks `/nix/var/nix/daemon-socket/socket`, so `nix flake check` exits with “Operation not permitted.” Evidence: running `just test` returns `error: cannot connect to socket at '/nix/var/nix/daemon-socket/socket': Operation not permitted`.
- Observation: `nix flake check` warns about dirty Git trees and the extra `deploy` output; the test recipe now disables the dirty-tree warning while leaving the deploy warning visible so logs stay readable when piped through helpers like `tee`.

## Decision Log

- Decision: Start the migration by adding a `just test` target that runs `nix flake check` against the root flake and every host and device within the selected cluster to catch regressions during directory moves. Rationale: test coverage is currently manual; adding automation first gives immediate safety rails for each incremental step while respecting future multi-cluster layouts. Date/Author: 2025-11-03 / Codex.
- Decision: Keep `CLUSTER` and `.cluster` values as cluster *names* (not arbitrary directories) so flake-relative imports remain stable and reproducible. Rationale: nix flakes require deterministic relative paths; mapping names to `./clusters/<name>` preserves simplicity while still allowing the default cluster to be overridden. Date/Author: 2025-11-03 / Codex.
- Decision: Allow cluster selection to fall back to the legacy `hosts/` and `devices/` directories until they are relocated under `clusters/<name>/`. Rationale: preserves deployability during the migration window and lets contributors test with `CLUSTER=<name>` before the directory exists. Date/Author: 2025-11-03 / Codex.
- Decision: Keep `settings.pubkey` and `settings.deployPubkey` in the cluster manifest alongside the new `sshKey` and `authorizedDeployKeys` fields. Rationale: existing modules and device scaffolding read the legacy attributes; dual-publishing avoids breakage while we refactor downstream consumers. Date/Author: 2025-11-03 / Codex.

## Outcomes & Retrospective

Pending; will summarize lessons and follow-ups after cluster decoupling work lands.

## Context and Orientation

The repository root (`/Users/gisikw/Projects/fort`) contains shared Nix modules under `common/`, reusable service definitions in `apps/`, `aspects/`, and `roles/`, and environment-specific manifests in `manifest.nix`, `devices/`, and `hosts/`. Each device subflake at `devices/<uuid>/flake.nix` imports `../../common/device.nix`, while each host subflake at `hosts/<name>/flake.nix` imports `../../common/host.nix`. The shared modules assume a single environment by importing `../manifest.nix` and walking into `../devices` and `../hosts`. Secrets are managed via `secrets.nix`, which enumerates device public keys by reading `./devices`. Operational tooling in `Justfile` shells out to `nix eval (import ./manifest.nix)` to discover the deployment domain and uses the hard-coded SSH key path `~/.ssh/fort` when provisioning or deploying. The repository does not yet define a testing command, so deploy safety relies on manual `nix flake check` runs. Our target state introduces `clusters/<clusterName>/` directories that house `manifest.nix`, `devices/`, and `hosts/` for each cluster (with `<clusterName>` coming from `CLUSTER` or `.cluster`), while keeping shared code (apps, aspects, roles, common modules, device profiles) at the root. The first such manifest now lives at `clusters/bedlam/manifest.nix`, mirroring the root settings while adding structured `sshKey` and `authorizedDeployKeys` metadata for downstream tooling.

## Plan of Work

Stage 1 — Add a `just test` recipe that shells into `nix flake check` for the root flake and, using the currently selected cluster name, iterates over every host and device subflake under `clusters/<clusterName>/`. Capture failures early by running this command in CI-equivalent conditions and documenting its use for future contributors.

Stage 2 — Introduce cluster selection scaffolding. Create `.cluster.example` (tracked) and ensure `.cluster` (ignored) records the default cluster name. Implement a helper module (placed at `common/cluster-context.nix`) that reads `CLUSTER` when set, falls back to `.cluster`, and otherwise defaults to `bedlam`. The helper should derive `clusterName`, `clusterDir = ./clusters/<clusterName>`, `hostsDir`, `devicesDir`, flags for whether the cluster directories/manifests exist, and expose `clusterManifestPath`. Update the root `manifest.nix` to call this helper, resolve to the cluster manifest when present, fall back to the legacy inline manifest when absent, set `fortConfig` and `module` from the resolved manifest, and expose `fort.cluster = context // { manifest = resolvedManifest; }` so existing consumers gain cluster metadata in one place.

Stage 3 — Extend cluster manifests. Create `clusters/bedlam/manifest.nix` by moving the existing `manifest.nix` content and reorganizing key metadata so it clearly distinguishes the deploy keypair and any additional authorized keys. For example, store `{ sshKey = { privatePath = "..."; publicKey = "..."; }; authorizedDeployKeys = [ ... ]; }`. Update the helper to import this manifest and surface these settings to callers. Temporarily keep a shim `manifest.nix` at the root that delegates to the helper so older paths continue to work while we refactor code.

Stage 4 — Thread cluster context through shared modules. Update `common/host.nix` and `common/device.nix` to replace hard-coded `../devices` and `../hosts` references with the paths provided by the helper. Ensure they set `config.fort.clusterDir`, `config.fort.clusterName`, and `config.fort.clusterSettings` so app, aspect, and role modules can discover paths without guessing. Audit the `mkModule` helper so it passes the new context into imported modules alongside `rootManifest`. Keep fallback logic active until all definitions move under `clusters/bedlam/`.

Stage 5 — Update secrets handling. Refactor `secrets.nix` to use the helper for clustering, limiting device key collection to `clusters/<clusterName>/devices` and preserving the existing `KEYED_FOR_DEVICES` behavior. Confirm that agenix rekeying still succeeds when run against the existing directory layout.

Stage 6 — Make the Just recipes cluster-aware. Replace the global `ssh` variable and any hard-coded paths with values derived from the helper via `nix eval --raw --expr '(import ./manifest.nix).fort.cluster.<attr>'`. Ensure `_scaffold-device-flake`, `_bootstrap-device`, `assign`, and `deploy` resolve paths such as `clusters/${clusterName}/devices` and `clusters/${clusterName}/hosts`. Allow an operator to override the cluster for a single command by exporting `CLUSTER` before running `just`. Document the new behavior within the recipes’ comments.

Stage 7 — Relocate configuration into `clusters/bedlam/` incrementally. First, move `hosts/` into `clusters/bedlam/hosts/` using `git mv` and update each host flake to reference the shared modules via the correct relative paths (likely `../../../../common/host.nix` and `path:../../../../`). Run `just test` to verify nothing regresses. Next, move `devices/` into `clusters/bedlam/devices/`, adjusting each device flake accordingly and retesting. Leave compatibility logic in place until both moves succeed.

Stage 8 — Update provisioning scaffolds. Modify `_scaffold-device-flake`, `_bootstrap-device`, `assign`, and supporting helpers to create new host and device directories under `clusters/${clusterName}` and to add files to git at the new locations. Ensure generated flakes emit the correct relative import paths so newly provisioned nodes immediately follow the cluster-aware layout.

Stage 9 — Retire fallback paths. After confirming `just test` passes and deploy tooling functions with the moved directories, remove any legacy fallbacks in the helper and shared modules that reference root-level `hosts/` or `devices/`. Replace the root-level `devices/` and `hosts/` entries with README stubs pointing developers toward `clusters/<clusterName>/` if needed. Drop the compatibility attributes (`settings.pubkey`, `settings.deployPubkey`) in favor of `sshKey` and `authorizedDeployKeys`, and delete the root `manifest.nix` entirely once all consumers read from `clusters/<clusterName>/manifest.nix`.

Stage 10 — Update documentation. Revise `README.md`, `AGENTS.md`, and any onboarding materials to explain the cluster selection flow, the location of cluster manifests, and how to use `.cluster`. Add notes on maintaining per-cluster SSH keys and on running `just test` before each deploy.

## Concrete Steps

Run all commands from `/Users/gisikw/Projects/fort` unless specified.

To add the test harness, implement Stage 1 and then execute:

    just test

Expect `nix flake check` to succeed for the root, each host, and each device, printing the standard “checked” summary with zero failures.

After introducing the cluster helper and new manifest structure (Stages 2–5), validate the environment resolution with:

    nix eval --impure --raw --expr '(import ./manifest.nix).fort.cluster.clusterName'
    CLUSTER=bedlam nix eval --impure --raw --expr '(import ./manifest.nix).fortConfig.settings.domain'
    nix eval --impure --raw --expr '(import ./manifest.nix).fort.cluster.hostsDir'

Each command should reflect the selected cluster (or the legacy fallback paths when the cluster directories are still in their original locations).

To switch clusters interactively (or to set the default), copy or edit the scalar value in `.cluster`:

    cp .cluster.example .cluster
    echo bedlam > .cluster

When relocating hosts and devices (Stage 7), move directories with:

    git mv hosts clusters/bedlam/hosts
    git mv devices clusters/bedlam/devices

Immediately edit the affected flakes to fix their relative imports, then re-run `just test` to confirm the workspace still passes checks.

After updating provisioning scaffolds (Stage 8), simulate host creation without touching hardware by running:

    just assign 801cc75b-726d-b24a-b46b-7015fb5bf9cd test-host

Use a sacrificial UUID and host name, then inspect the resulting files to confirm they appear under `clusters/bedlam/hosts/test-host/`; remove the test host directory afterward to keep the tree clean.

## Validation and Acceptance

Successful completion requires that `just test` passes with no modifications to the working tree, both with and without explicitly setting `CLUSTER=bedlam`. `nix eval --impure --raw --expr '(import ./clusters/bedlam/manifest.nix).fortConfig.settings.domain'` must match the routed value from the cluster-aware shim. Running `just deploy <host>` against an existing node should reuse the cluster-specific SSH key path defined in the manifest and succeed in fingerprint verification without manual patching.

## Idempotence and Recovery

The new `just test` command and the cluster helper are safe to run repeatedly. Moving directories with `git mv` is idempotent as long as it completes before commits are made; if a move fails, reset the affected paths before retrying. The helper should detect missing clusters and emit clear errors, allowing operators to restore `.cluster` or re-export `CLUSTER`. Keep backup copies of `hosts/` and `devices/` until Stage 7 succeeds to simplify rollbacks.

## Artifacts and Notes

Capture the first successful `just test` transcript and attach it to the decision log when Stage 1 lands. When clusters become selectable, record the output of both `nix eval` commands (with and without `CLUSTER`) as evidence. During directory moves, note any manual edits required for relative paths so future scaffolding updates remain accurate.

## Interfaces and Dependencies

Define cluster manifests at `clusters/<clusterName>/manifest.nix` to export an attribute set with at least:

    rec {
      name = "<clusterName>";
      fortConfig = {
        settings = {
          domain = "...";
          dnsProvider = "...";
          sshKey = {
            publicKey = "...";
            privateKeyPath = "/Users/.../.ssh/fort-bedlam";
          };
          authorizedDeployKeys = [ "... additional pubkeys ..." ];
        };
      };
      module = { config, ... }: { ... };
    }

The helper in `common/cluster-context.nix` now exposes:

    {
      clusterName = "...";
      clusterDir = ./clusters/<clusterName>;
      hostsDir = clusterDir + "/hosts";  # falls back to ./hosts until moved
      devicesDir = clusterDir + "/devices";  # falls back to ./devices until moved
      clusterManifestPath = clusterDir + "/manifest.nix";
      hasClusterManifest = true|false;
      rootDir = ./.;
    }

`common/host.nix` and `common/device.nix` must read these attributes instead of hard-coded relative paths and must set `config.fort.clusterDir = clusterDir` so downstream modules can reach per-cluster assets. The Just recipes must resolve the deploy key path via `manifest.fortConfig.settings.sshKey.privateKeyPath` (or whichever structure we finalize) and never assume `~/.ssh/fort`.

---

Revision 2025-11-03: Incorporated stakeholder feedback to keep `CLUSTER` values as names, clarify Stage 2 helper responsibilities, restructure key metadata, adjust testing scope to be cluster-aware, and place the helper under `common/`.
