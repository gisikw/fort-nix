# DONE — control-plane decomposition theme

Branch: `burn/control-plane-decomp` (off `burn/darwin-parity`, with
`burn/cert-lifecycle` merged in as the verification baseline). Nothing
deployed; no live-host changes; `flake.lock` and all per-host locks
untouched (`git diff main...HEAD -- '*lock*'` is empty). The parent lanes'
DONE.md records live on their own branches; this file supersedes the
concatenated copy from the merge commit.

## Base merge (verified before any decomp work)

- `e32bff8` merges `burn/cert-lifecycle` into this branch. The predicted
  conflicts from the cert-lifecycle audit §5 auto-merged cleanly
  (certificate-broker take-both landed as gate-on-top + new-body-below;
  control-plane.nix hunks were disjoint). The only manual conflict was an
  undocumented add/add on `DONE.md` (both lanes wrote one) — resolved by
  concatenation, superseded by this file.
- Union verified green: full `just test` (root + 14 host flakes + device
  flakes) passed on the merge commit.
- **Verification baseline**: toplevel `drvPath` snapshotted for all 13
  NixOS hosts + obrien (darwin) at the merge commit. All drv-diff claims
  below are against this snapshot, not main.

## Quest dispositions

### q-d9cba37c — Decompose common/fort.nix — DONE (`b92425e`, [low])

`common/fort.nix` (680 lines) split by concern into `common/fort/`:

| File | Concern |
|------|---------|
| `services.nix` | host-manifest generation + discovery needs (proxy, dns-headscale, dns-coredns) |
| `nginx.nix` | realip/geo/hop-header plumbing + per-service virtual hosts + firewall |
| `auth.nix` | oauth2-proxy instances, identity-proxy, token secret, oidc-register needs |
| `ssl.nix` | placeholder certs + ssl-cert need with freshness probe |
| `service-lib.nix` | shared pure helpers (subdomainOf, hostManifestContentFor) |

Naming note: the quest suggested `services/nginx/auth`; `ssl.nix` was added
as a fourth concern (the quest listed SSL cert handling as a mixed concern)
and "service exposure" landed as manifest+discovery bookkeeping in
`services.nix`.

**Design constraint discovered**: the aggregator composes the concern
modules *functionally* (one module, configs merged in pre-split order)
rather than via `imports`. The module system expands `imports`
breadth-first (`genericClosure`), which pushes imported definitions AFTER
the host's aspect/app modules and reorders list-typed option merges —
observed concretely as nginx `ReadWritePaths` flipping order with
`aspects/host-status`, changing the unit file. The functional composition
preserves definition order byte-for-byte; the header comment in fort.nix
documents why.

Verified: full-fleet drv sweep after the commit — **all 14 hosts
byte-identical to baseline**.

### q-1f08acd9 — Factor shared control-plane logic — DONE, honest-remainder scope (`5c4008b`, [low])

The honest answer the brief anticipated: **darwin-parity (and the work it
built on) already did most of this.** `common/fort/control-plane.nix` is
already a single shared module — both platform builders import it (darwin
with `platform = "darwin"`), and all handlers/consumer/GC logic is shared
with explicit `isDarwin` branches. There was no NixOS-only module left
holding hostage logic that darwin needs, with one small exception (below).

Remainder actually done:

- Structural decomposition of the 1783-line file into
  `common/fort/control-plane/`: `handlers.nix` (the 8 mandatory capability
  handlers + sanitizeJournalOutput), `options.nix` (need/capability option
  types), `fulfill.nix` (the consumer fulfill loop). The top-level
  `control-plane.nix` (624 lines) is now data derivation (hosts.json, RBAC,
  needs.json) + platform wiring (systemd vs launchd) — the shared/platform
  boundary is now file-level, not buried in a monolith.
- The one real duplication: host-manifest.json construction existed twice
  (NixOS in `fort.nix`, darwin in `control-plane.nix`). Both now share
  `service-lib.nix#hostManifestContentFor`; each platform keeps its own
  byte-identical wrapper (`builtins.toFile` vs `pkgs.writeText`) because
  changing either wrapper would change that platform's drv.

Verified: full-fleet drv sweep after the commit — **all 14 hosts (incl.
obrien darwin) byte-identical to baseline**. Tier-1 boundary `just test`
green.

### q-1e0a32ed — Declared overlay dependencies — DONE (`af64648`, [med])

- Host manifests: `overlays.<name>.dependsOn = [ "other-overlay" ]`,
  validated at eval time (throws if the dep isn't declared on the host).
- Manager (`pkgs/fort-overlay-manager`): activation processes overlays in
  dependency order (deterministic DFS topo sort, name-ordered ties,
  cycle-tolerant with a logged warning) in both `check` and `boot`.
- systemd-level guarantee: the overlay's target gets `Wants=`/`After=` on
  each dependency's target, and each *service* unit gets `After=` on them
  too (a target's own `After=` does not order its wanted services). Target
  units implicitly order `After=` their `Wants=`, so a dependency's
  services have started before the dependent target activates.
- First user: `discovery-zone.dependsOn = [ "knockout" ]` on ratched (the
  quest's own example — previously an implicit /run/overlays/bin PATH dep).
- Scope note: ordering is start-ordering, not health-gating — a dependent
  starts once the dependency's services have *started*, not once healthy.
  Health-gated deps would need the manager to consult health state across
  overlays; not needed for the current dep (CLI on PATH) so not built.
- Includes a `gofmt` pass over main.go (pre-existing misalignment).

### q-9f7a3b5b — Drain hooks — DONE, propose-and-implement (`df3cf1f`, [med])

Body was empty; scoped minimally. **Design decision**: the drain hook is
systemd's native drain point, `ExecStop=`. overlay.nix services gain an
optional `drain` (string command) written into the generated unit; systemd
runs it while the service is still up and only signals remaining processes
after it exits, bounded by the existing `timeoutStopSec`. Why this shape:

- Stop, replace, and rollback all drain via the same path with zero manager
  orchestration — no new states in the activation state machine.
- The *running* unit file carries its own version's drain command, so a
  replace drains the old process with the drain logic matching the old
  binary (a manager-side hook would have run the new version's drain
  against the old process).
- Rejected alternatives: a manager-executed pre-stop command (wrong-version
  problem above, plus duplicate timeout bookkeeping); a health-type-like
  drain endpoint (HTTP-only, and ExecStop can curl an endpoint anyway).

No current overlay declares `drain`; it becomes available to project repos'
overlay.nix immediately after deploy (no fort-nix change needed per-project).

### q-b5f9ad4b — Flatten overlay unit naming — DONE (`dbfb163`, [med], intentionally last/droppable)

New scheme: a service named after its overlay generates
`overlay-<name>.service` (was `overlay-<name>-<name>.service`); distinct
service names keep the namespaced `overlay-<overlay>-<service>.service`
(full flattening was rejected — two overlays could both define a service
named e.g. `web` and collide). Targets unchanged (`overlay-<name>.target`).

**Renamed units** (enumerated from live `/run/systemd/system` on the
overlay hosts via `fort read-file`):

| Host | Renamed | Unchanged |
|------|---------|-----------|
| ratched | overlay-{cranium,cupola,discovery-zone,headjack,knockout,kobold,lair,litmus,questbook}.service (9) | — |
| lordhenry | overlay-{grotto,tiamat}.service (2) | overlay-kobold-worker.service (service `worker` ≠ overlay `kobold`) |
| frankenstein | — (unkork has no generated service units yet) | — |
| (ratched) muse, phylactery | — (targets only, no service units) | — |

**Migration** is self-contained in the manager: when a pre-flattening unit
file exists, `generateUnits` stops that unit *before* removing it (so the
renamed unit doesn't double-run into port conflicts when
`fort-overlay-manager-boot` regenerates after the deploy), and
`stopServices` also stops the legacy name as belt-and-braces. Expect one
brief stop/start per renamed service on the first activation after deploy.

**References audited and updated** (repo-wide grep over nix/md/go/js/sh/yml):

- `clusters/bedlam/hosts/lordhenry/manifest.nix` — tiamat anthropic-secret
  drop-in dir (`overlay-tiamat.service.d/`, with `rm -rf` of the stale
  pre-rename dir) and `tiamat-profiles-provision.before`.
- `AGENTS.md` — unit-naming line rewritten for the new scheme.
- `pkgs/fort-overlay-manager/main.go` — all generation/stop sites go
  through `serviceUnitName`/`legacyServiceUnitName`.
- No other in-repo references exist (fort capabilities take unit names as
  request parameters; nothing hardcodes overlay unit names).

## Verification record

Executed on this branch (Linux dev sandbox; no darwin hardware):

1. **Baseline**: merge commit `e32bff8` — `just test` green; drvPath
   snapshot for all 14 hosts (13 NixOS + obrien darwin).
2. **After factoring tier** (q-d9cba37c, then again after q-1f08acd9):
   full-fleet drv sweep — **zero changes**; every host's toplevel drvPath
   byte-identical to baseline, including obrien's darwinConfigurations
   (which also keeps the CI darwin force-eval covered — the release.yml
   step from darwin-parity is untouched). `just test` green at the tier
   boundary.
3. **After overlay tier** (q-1e0a32ed + q-9f7a3b5b): `just test` green.
   Drv sweep — exactly three hosts changed, all mapped:
   - ratched, lordhenry, frankenstein → fort-overlay-manager rebuild
     (refresh handler in /etc + manager units) and /etc/fort/overlays.json
     gaining `dependsOn`; ratched additionally the discovery-zone
     declaration. All are overlay hosts; doofenshmirtz (empty `overlays =
     {}`) correctly unchanged; the other 10 NixOS hosts + obrien
     byte-identical. Nothing unmapped.
4. **After rename tier** (q-b5f9ad4b): `just test` green. Drv sweep vs
   tier-2: same three hosts changed (manager rebuild; lordhenry also the
   tiamat drop-in path + activation script). All other hosts byte-identical
   to baseline. Nothing unmapped.
5. `go build ./...` + `go vet` + `gofmt -l` clean in
   `pkgs/fort-overlay-manager` at every commit touching it (no test files
   exist in the package — pre-existing).
6. `git diff main...HEAD` touches no lockfile.

## Questbook true-up notes (for merge review)

- **q-d9cba37c**: close on merge. Note for the record: aggregation must
  stay functional-composition, not `imports` (ordering hazard documented in
  `common/fort.nix` header).
- **q-1f08acd9**: close on merge, with the honest note that darwin-parity
  had already done the platform-sharing substance; this quest's residue was
  file-level decomposition + the host-manifest dedup. If the quest's intent
  was something larger (e.g. extracting a reusable control-plane library
  for non-fort consumers), it should be re-scoped as a new quest.
- **q-1e0a32ed**: close on merge. Follow-on candidate if ever needed:
  health-gated dependencies (start-ordering only today).
- **q-9f7a3b5b**: close on merge. The `drain` field is live but unused;
  first consumer should be whichever overlay next needs graceful shutdown
  (litmus/tiamat are the likely candidates).
- **q-b5f9ad4b**: close on merge **after** the Kevin-side follow-ups below
  are triaged, since the rename is visible outside this repo.

## Kevin-side follow-ups (out of repo — deliberately not chased)

1. **Other repos / muscle memory that reference old unit names** in
   `fort <host> journal/systemd` calls (e.g.
   `{"unit":"overlay-knockout-knockout"}`) — anything scripted in project
   repos' CI, runbooks, dashboards, or shell history. In-repo audit found
   nothing, but litmus/knockout/headjack/tiamat repos and any monitoring
   config were out of scope.
2. **Deploy sequencing for the rename**: on each overlay host the rename
   lands at the first `fort-overlay-manager-boot` run after switch, with
   one stop/start per renamed service. If tiamat mid-run interruption is
   costly, deploy lordhenry at a quiet moment.
3. **Stale drop-in dir on lordhenry** is cleaned by the activation script;
   if the deploy is ever rolled back past this branch, the old
   `overlay-tiamat-tiamat.service.d` would need restoring by re-activation.
4. **Merge order** stands as briefed: darwin-parity → cert-lifecycle →
   this branch. Both parents were frozen; if merge review trims them, this
   branch rebases through the certificate-broker header and
   control-plane.nix hunks (now split across `common/fort/control-plane/`).
5. **Runtime verification after deploy** (nothing was deployed from this
   branch): `fort ratched status`, `systemctl status overlay-knockout` on
   ratched, one `fort ratched refresh '{"overlay":"discovery-zone"}'` to
   watch the ordered activation, and `journalctl -u overlay-tiamat` on
   lordhenry to confirm the drop-in still applies (Environment from
   10-anthropic-secret-file.conf).
