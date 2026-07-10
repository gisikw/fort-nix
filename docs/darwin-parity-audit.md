# Darwin Parity Audit

Audit of Linux-specific assumptions in fort-nix host infrastructure, the fort
control plane, and gitops — with parameterization fixes applied on branch
`burn/darwin-parity`. Goal: make the Mac mini (obrien) a first-class citizen
wherever that is achievable without Darwin hardware or live-infra changes.

**Method**: full read of `common/`, `aspects/`, `roles/`, `core/`,
`device-profiles/`, `clusters/bedlam/`, `pkgs/fort*`, `apps/fort-*`, plus
repo-wide greps for `systemctl|journalctl|/etc/systemd|/proc/|
nixosConfigurations`. Every fix was verified by drv-path comparison for a
production NixOS host (ratched) against `main`, plus eval of obrien's
`darwinConfigurations`. This box is a Linux dev sandbox: nothing here was
executed on Darwin hardware. Each item below is marked **verified** (eval/drv
or build proven), **eval-only** (evaluates, runtime untested), or
**untestable here** (needs the Mac mini).

Risk tiers refer to the commit prefixes on this branch: `[low]` = darwin-only
code paths / additions with drv-identical Linux output, `[med]` = shared-code
refactors with drv-diff evidence, `[high]` = not used (nothing on this branch
changes what a Linux host evaluates to — ratched's drvPath is byte-identical
to main across the whole branch).

---

## 1. What was already first-class (no changes needed)

| Area | Location | Notes |
|------|----------|-------|
| Platform dispatch | `common/host.nix:25,122-132` | `deviceProfileManifest.platform` selects `platforms/nixos.nix` vs `platforms/darwin.nix` |
| Darwin platform builder | `common/platforms/darwin.nix` | sops-nix, fort-options, control-plane (`platform = "darwin"`), authorized-keys activation |
| Control plane handlers | `common/fort/control-plane.nix` | `status`/`journal`/`systemd`/`force-nag` already branch on `isDarwin` (sysctl, `log show`, `launchctl`); seed quests q-6b76fb89 / q-54520608 / q-4c48ba93 are substantially implemented on main |
| Provider/consumer/GC services | `common/fort/control-plane.nix:1459-1478,1534-1548,1645-1659` | launchd daemons with `StartInterval`, direct HTTPS (`--listen 0.0.0.0:443` + self-signed cert) instead of nginx+FastCGI |
| mesh aspect | `aspects/mesh/default.nix` | `lib.optionals` platform branching; darwin path: tailscale + `/etc/resolver` + launchd enrollment |
| gitops aspect | `aspects/gitops/default.nix` | single file, `if isDarwin` branch: launchd 30s poll + `darwin-rebuild switch` |
| observable aspect | `aspects/observable/default.nix` | gated `lib.mkIf (platform == "nixos")`; no-op on obrien |
| deployer, agent-debug aspects | `aspects/deployer/`, `aspects/agent-debug/` | platform-agnostic options only |
| fort CLI | `pkgs/fort/default.nix:4-6,156,168` | `stdenv.isDarwin` picks `/bin/hostname` vs nettools; `curl -sk` accommodates darwin's self-signed provider cert; `platforms.linux ++ platforms.darwin` |
| fort-provider (Go) | `pkgs/fort-provider/main.go` | dual mode: FastCGI-on-stdin (NixOS, socket-activated) vs `--listen`/`--tls-cert`/`--tls-key` HTTPS (darwin); no Linux syscalls; `--trigger`/`--gc`/callbacks are pure Go + `fort` CLI |
| fort-tokens (Go) | `pkgs/fort-tokens/` | portable (cgo sqlite, plain HTTP listen, `/var/lib` paths) |
| device.nix | `common/device.nix:15-17` | returns `{ }` for non-nixos platforms — darwin devices produce no nixosConfigurations |
| fort-options.nix | `common/fort-options.nix` | shared on both platforms; pure option declarations, no systemd/nginx types |
| cluster-context.nix | `common/cluster-context.nix` | platform-free |
| mac-mini profile | `device-profiles/mac-mini/manifest.nix` | `platform = "darwin"`, `system = "aarch64-darwin"`, nix-darwin-only options |
| Provision/deploy tooling | `justfile` (`provision`, `_fingerprint-darwin`, `_bootstrap-darwin`, `deploy` → `_deploy-direct-darwin`) | routes by profile platform |
| rekey script | `scripts/rekey.sh:73` | tries nixosConfigurations, falls back to darwinConfigurations |

## 2. Linux-isms found and FIXED on this branch

### Control plane handlers (tier: low — darwin-only branches, ratched drv unchanged)

| # | Finding | Location | Fix | Verification |
|---|---------|----------|-----|--------------|
| 1 | Darwin `journal` handler returned empty results (seed quest q-314c1d31): launchd daemons here log via `StandardOutPath` to `/var/log/<name>.log`, which never reaches the unified log, so any `log show` predicate misses them. Also `--last "${lines}m"` conflated line count with a minutes window, and `log show` without `--info` drops info-level messages. | `common/fort/control-plane.nix` (darwin branch of `mandatoryHandlers.journal`) | Prefer `/var/log/<unit>.log` when present (also mapping `network.gisi.*` labels back to file names, e.g. `network.gisi.fort.provider` → `fort-provider.log`); fall back to `log show` with `--info --debug`, a fixed `--last 1h` window (or `since`), and a predicate extended with `processImagePath` | eval-only (obrien drv evaluates; runtime needs hardware) |
| 2 | Darwin `systemd` handler restart used `launchctl kickstart -k`, which respects launchd's spawn throttle — a service that crashed recently (typical right after reboot) refuses to restart (seed quest q-d9b7ef7b, which called for bootout/bootstrap). | `common/fort/control-plane.nix` (darwin branch of `mandatoryHandlers.systemd`) | `restart` now does `launchctl bootout` + `launchctl bootstrap system /Library/LaunchDaemons/<label>.plist` when the plist exists (clears the throttle), falling back to `kickstart -k`; `stop` uses `bootout` (SIGTERM alone is undone by `KeepAlive`); `start` bootstraps unloaded services | eval-only |
| 3 | Short unit names didn't resolve to launchd labels: `resolve_target` was a stub that always returned `system/$label`, so `fort obrien systemd '{"unit":"fort-provider"}'` missed `network.gisi.fort.provider`. | same | `resolve_label` scans `launchctl list` for a suffix match treating `-`/`.` as interchangeable; used by restart/start/stop/status | eval-only |
| 4 | fort-provider on darwin subject to launchd default 10s throttle when crash-looping at boot (network/TLS state not ready). | `common/fort/control-plane.nix` (darwin `launchd.daemons.fort-provider`) | `ThrottleInterval = 5` | eval-only |

### GitOps (tier: low — darwin script only; NixOS `gitopsScript` untouched)

| # | Finding | Location | Fix | Verification |
|---|---------|----------|-----|--------------|
| 5 | Darwin gitops-lite tracked nothing: compared git HEAD to origin/main, never wrote `deployed-commit`, had no failure tracking — so a bad commit was retried at full darwin-rebuild cost every 30s forever, and nothing could report what is deployed. | `aspects/gitops/default.nix` (`darwinRebuildScript`) | Converged on the NixOS state model: compares `deployed-commit` against origin/main, writes it on successful switch, and applies the same exponential backoff (`60s * 2^(n-1)`, cap 6) via the same `switch-failures`/`last-failure-time`/`failing-commit` files in `/var/lib/fort-gitops` | eval-only |

Deliberate divergence kept (documented, not fixed): darwin runs the switch
inline rather than via a detached unit (`systemd-run` has no clean launchd
equivalent; `darwin-rebuild` is idempotent so a mid-switch kill is retried
next tick), writes `deployed-commit` after success rather than before, has no
rollback (no `switch-to-configuration`/profile-generation mechanism to roll
back *to* on darwin — nix-darwin activation is not generation-pinned the same
way), and has no `manualDeploy` mode / `deploy` capability. See §4.

### Host status (tier: low for the aspect branch, med for the host.nix default)

| # | Finding | Location | Fix | Verification |
|---|---------|----------|-----|--------------|
| 6 | `host-status` was NixOS-only (`/proc/uptime`, `systemctl is-system-running`, systemd timer, nginx vhost, upload socket), so darwin hosts never produced `status.json` — `fort obrien status` fell back to a bare uptime with `status: "unknown"` and no deploy info. | `aspects/host-status/default.nix` | Platform branch: darwin gets a launchd daemon (30s) writing the same-shaped `status.json` from `sysctl kern.boottime` (uptime), `launchctl list` (failed units → running/degraded), and `/var/lib/fort-gitops/deployed-commit` (deploy info, which fix #5 now populates). Nginx vhost/HTML page/upload endpoint remain NixOS-only. Linux body byte-identical. | drv-verified (ratched unchanged) / eval-only on darwin |
| 7 | `host-status` excluded from darwin default aspects. | `common/host.nix:39` | Default aspects are now `mesh`, `gitops`, `host-status` on both platforms (+ `emergency-reboot` NixOS-only). NixOS list is order-identical to before. | drv-verified (ratched unchanged) |

### Aspect gating (tier: med — 14 files, drv-verified no-op on Linux)

If a darwin host manifest listed any Linux-only aspect, evaluation failed with
a cryptic `option 'systemd.services' does not exist` (or silently
half-applied, for aspects whose options happen to exist in nix-darwin). Each
of these now fails fast with
`fort-nix: aspect '<name>' is Linux-only (<reason>); remove it from this darwin host's manifest`:

| Aspect | Representative Linux-isms |
|--------|---------------------------|
| backup-client | `services.restic` systemd timers |
| certificate-broker | `security.acme`, `systemd.services.fort-ssl-local-copy`, acme unit `OnSuccess` |
| ci-runner | `systemd.services.ci-runner*`, `services.postgresql` |
| dev-sandbox | ~10 systemd services/timers, `environment.persistence` |
| egress-vpn | `ip netns`, iptables, wg-quick, `/etc/netns` |
| ldap | `services.lldap`, bootstrap systemd unit |
| media-kiosk | greetd/Cage/pipewire, impermanence, PAM |
| mosquitto | `services.mosquitto` NixOS module |
| nvidia-gpu | `hardware.nvidia*`, `services.xserver.videoDrivers` |
| public-ingress | nginx/ACME wiring, `systemd.tmpfiles` |
| wifi-access | NetworkManager, impermanence |
| zfs | `boot.*` kernel modules, `networking.hostId`, zfs systemd import unit |
| zigbee2mqtt | `services.zigbee2mqtt`, `dialout` serial group |
| zwave-js-ui | `systemd.services.zwave-js-ui*` |

These are inherently Linux (hardware/kernel/desktop) or blocked on NixOS
modules with no nix-darwin equivalent; explicit gating (fail loudly with a
clear message) was chosen over silent no-op, because a silently-skipped
backup-client or certificate-broker is a misconfiguration you want to know
about. `observable` (pre-existing) remains a silent no-op on darwin, which is
appropriate for a metrics exporter.

**emergency-reboot is the deliberate exception**: it embeds its Go source
next to `default.nix` with `src = ./.;`, so *any* edit to its `default.nix`
changes the package hash and rebuilds the unit on **every** NixOS host
(proven by drv diff while attempting the gate — same trap as
fort-overlay-manager in §2/#9). It is already platform-gated at its only
call site (`common/host.nix` adds it to defaults only when
`platform == "nixos"`), so the in-file gate was reverted to preserve
branch-wide drv identity. A darwin host that *explicitly* lists
`emergency-reboot` in its manifest still gets the old cryptic
option-does-not-exist error. General hazard worth knowing: an aspect or
package whose build `src` includes its own `default.nix` cannot have that
file touched without a fleet-wide rebuild.

### CI (tier: low — additive workflow step)

| # | Finding | Location | Fix |
|---|---------|----------|-----|
| 8 | `nix flake check` on obrien's host flake recognizes `darwinConfigurations` but does not deep-evaluate configurations for systems incompatible with the checker (aarch64-darwin on Linux CI) — verified: the check returns in seconds while a full toplevel eval takes ~1 min. Darwin eval breakage would reach the gitops agent on the Mac mini before CI noticed. | `.forgejo/workflows/release.yml` (check job) | New step force-evaluates `darwinConfigurations.<host>.config.system.build.toplevel.drvPath` for every host flake exposing darwinConfigurations |

### Packaging hygiene (documented, deliberately NOT changed)

| # | Finding | Location | Disposition |
|---|---------|----------|-------------|
| 9 | `fort-overlay-manager` writes `/run/systemd/system` units and shells out to `systemctl` (`main.go:432,522-542`) but declares no `meta.platforms` restriction. It is correctly gated in practice — `common/fort/overlays.nix` is imported only by `common/platforms/nixos.nix:101`. | `pkgs/fort-overlay-manager/default.nix` | Documented here instead of in-file: the package uses `src = ./.;`, so touching its `default.nix` changes the source hash and rebuilds the binary — which cascades into the `refresh` handler embedded in `/etc` on **every** NixOS host (verified by drv diff while attempting the change). Not worth breaking the branch-wide drv-identity guarantee for a metadata comment. |

## 3. Linux-isms found and left alone (correct as-is)

| Finding | Location | Why no change |
|---------|----------|---------------|
| `common/fort.nix` (nginx exposure, oauth2-proxy, systemd units, host-manifest activation) | `common/fort.nix` throughout | Only imported by the NixOS platform builder (`platforms/nixos.nix:86`); darwin generates `host-manifest.json` in control-plane instead (`control-plane.nix:1275-1277`) |
| `common/fort/overlays.nix` (overlay manager systemd units) | imported at `platforms/nixos.nix:101` only | Overlay system is deliberately NixOS-only; darwin hosts declaring `overlays` in a manifest would be silently ignored — acceptable, documented here |
| fort-upload FastCGI-on-stdin + `platforms.linux` | `pkgs/fort-upload/main.go:47-51` | Upload path is nginx+systemd-socket-activation by design; darwin has no nginx. Upload to darwin hosts is a functional gap, see §4 |
| `roles/beacon.nix`, `roles/forge.nix` | pull in Linux-only aspects/apps | Roles are infrastructure roles for NixOS hosts; now protected by the aspect gates anyway |
| `core/` (router mini-flake: `http.nix` systemctl, `/proc/meminfo`, ip route) | `core/http.nix:26-32` etc. | Separate bootstrap flake for the router appliance; never evaluated for cluster hosts, inherently Linux hardware |
| 44 of ~60 `apps/` are systemd/nginx-based | `apps/*/default.nix` | Apps are opt-in per host manifest; obrien lists none. Same failure mode as ungated aspects in principle, but gating every app is high-churn/low-value — a darwin host adding `"jellyfin"` fails at eval, visibly. Documented convention instead (see §5) |
| `fort.cluster.services` declared on darwin does nothing (no nginx/fort.nix consumer) | `common/fort-options.nix` + `common/fort.nix` | The option evaluates fine and lands in `host-manifest.json` for discovery; there is simply no ingress on darwin. Fine for a dev box; revisit if darwin ever needs exposed services |
| `sse-probe` marked `platforms.linux` despite portable code | `pkgs/sse-probe/default.nix:12` | Nothing needs it on darwin; loosening is cosmetic churn |
| identity-proxy hardcodes `/var/run/tailscale/tailscaled.sock` | `pkgs/identity-proxy/main.go:451,463` | Outside audit scope (not a fort-* package, Linux-hosted only); noted for future parameterization if ever run on darwin |

## 4. Known gaps that need Darwin hardware or a Kevin decision

None of these are addressable confidently from a Linux sandbox; they are the
honest remainder.

1. **Runtime verification of every darwin-branch fix in §2** (journal file
   fallback, bootout/bootstrap restart, label resolution, status.json writer,
   gitops backoff). All eval-only. Suggested smoke test on obrien after
   cherry-pick, in order: `fort obrien status` (expect `status: "running"`,
   real uptime, deploy commit), `fort obrien journal '{"unit":"fort-provider"}'`
   (expect log lines), `fort obrien systemd '{"action":"restart","unit":"fort-provider"}'`
   twice in quick succession (expect both to succeed — the second used to
   throttle), `fort obrien systemd '{"action":"list"}'`.
2. **q-d9b7ef7b root cause**: `ThrottleInterval = 5` + bootout/bootstrap
   restart should clear the post-reboot throttle symptom, but why the
   provider exits at boot (network-up race? cert dir not yet created?) can
   only be diagnosed on the box (`/var/log/fort-provider.log`).
3. **Darwin rollback**: no equivalent of the NixOS
   `nix-env --set $PREV_GEN && switch-to-configuration switch` rollback.
   nix-darwin does keep system profile generations
   (`/nix/var/nix/profiles/system-profiles`), so a
   `darwin-rebuild --rollback`-style recovery on switch failure is plausible
   — but activating an old generation over a half-applied new one needs
   real-machine testing. Decision + hardware.
4. **Manual-confirmation deploys on darwin** (`manualDeploy` + `deploy`
   capability): straightforward to port now that state files exist
   (build with `darwin-rebuild build`, write `pending-commit`, confirm via
   handler), but obrien is auto-deploy and there is no current need. Decision.
5. **Test-branch support (`<host>-test`)**: neither platform's gitops script
   in this repo implements it (both are hardcoded to `main` —
   `aspects/gitops/default.nix` clone/fetch of `origin/main`); if the
   test-branch flow documented in AGENTS.md is implemented elsewhere/planned,
   darwin should get it at the same time. Flagging because AGENTS.md
   describes it as an existing workflow.
6. **File upload to darwin hosts**: `/upload` is nginx+fort-upload
   (socket-activated FastCGI), NixOS-only. If wanted on darwin, fort-provider
   could grow an upload route (it already terminates HTTPS). Decision.
7. **Emergency reboot for darwin**: NixOS aspect uses a netfilter-triggered
   watchdog; a darwin equivalent would be a different design entirely.
   Probably unnecessary for a dev box. Decision.
8. **Attic cache push after darwin switches**: `postDeployScript` pushes
   `/nix/var/nix/profiles/system` — NixOS profile path. Darwin builds are not
   pushed to cache (each Mac rebuilds from source). Worth doing once there
   are >1 darwin hosts; needs the darwin system profile path and hardware
   testing.
9. **A second darwin host would surface**: the darwin default aspect list is
   still minimal; `backup-client` for `/var/lib` on darwin, observability
   (node-exporter equivalent), etc. are all unported. Scope decision.

## 5. Conventions established / to follow

- **Aspects** must either branch on `deviceProfileManifest.platform` (like
  mesh/gitops/host-status), no-op via `lib.mkIf` (observable), or fail fast
  with a descriptive `throw` (all remaining Linux-only aspects, per this
  branch). New aspects should pick one explicitly.
- **Apps** remain NixOS-only by convention; a darwin-capable app should
  follow the aspect branching pattern. (Not enforced at eval time.)
- **Handlers in control-plane.nix**: keep the `isDarwin` string-branch
  pattern; note the shared `sanitizeJournalOutput` python is used by both
  platforms — changing it changes every Linux host's drv.
- **launchd daemons** should set `StandardOutPath`/`StandardErrorPath` to
  `/var/log/<name>.log` — the darwin journal handler now depends on that
  convention (it maps `network.gisi.foo.bar` labels to `foo-bar.log`).
- **CI**: darwin hosts are covered by the explicit
  `darwinConfigurations` eval step in `release.yml`; `nix flake check` alone
  does not cover them.

## 6. Verification record

Executed on this branch (Linux dev sandbox, see DONE.md for full transcript):

- `git diff main -- flake.lock` — empty (no lockfile touched, incl. per-host locks).
- `nix eval ./clusters/bedlam/hosts/ratched#nixosConfigurations.ratched.config.system.build.toplevel.drvPath`
  — **identical to main** (`p7n5pb0rgh6ajmm3c9xjplrfhapk143r-nixos-system-ratched-…`)
  after all tiers, i.e. the entire branch is a provable no-op for ratched.
- Additional NixOS hosts drv-compared against main after all tiers: see DONE.md.
- `nix eval ./clusters/bedlam/hosts/obrien#darwinConfigurations.obrien.…drvPath`
  — evaluates cleanly on the branch (drv changes as intended: new
  host-status daemon, updated handlers/gitops script).
- `nix flake check` on the root flake and per-host flake checks (`just test`
  equivalent) — see DONE.md for the exact set run and results.
- `go build ./...` + `go test ./...` in `pkgs/fort-provider`, `pkgs/fort-upload`,
  `pkgs/fort-tokens`, `pkgs/fort-overlay-manager` — build clean; no test
  files exist in any fort package (pre-existing; noted as future work).
- Aspect gate behavior spot-checked by evaluating a synthetic darwin host
  with a gated aspect (expect the descriptive throw) — see DONE.md.
