# DONE — Darwin parity audit + parameterization

Branch: `burn/darwin-parity` (7 code/doc commits + this file). Full inventory
and rationale live in `docs/darwin-parity-audit.md`; this file is the
execution summary.

## What was done

1. **Audited** `common/`, `aspects/`, `roles/`, `core/`, `device-profiles/`,
   `clusters/bedlam/`, `pkgs/fort*`, `apps/fort-*`, gitops, and CI for
   Linux-specific assumptions (four parallel deep-read passes + repo-wide
   greps). Big picture: the platform dispatch, control-plane launchd
   services, mesh, and gitops-lite were already in place on main; the seed
   quests q-6b76fb89 / q-54520608 / q-4c48ba93 are substantially done there.
   The real gaps were the two open bugs (journal, launchd throttle), missing
   status/deploy state on darwin, and ungated Linux-only aspects.
2. **Fixed** the darwin journal handler (q-314c1d31), the launchd restart
   throttle + label resolution (q-d9b7ef7b), gave darwin gitops
   deployed-commit tracking + exponential failure backoff, ported
   host-status to darwin (launchd status.json writer, now a default aspect
   on both platforms — `fort obrien status` gets real uptime/failed-units/
   deploy data), added explicit fail-fast platform gates to 14 Linux-only
   aspects, and made CI force-evaluate `darwinConfigurations`.
3. **Documented** everything else: what's correctly gated by architecture,
   what was deliberately left alone (and the two `src = ./.` traps that make
   "free" edits impossible in emergency-reboot and fort-overlay-manager),
   and what needs hardware or a decision (§3–4 of the audit doc).

## Commits (low → med; docs last, doc-only)

| Commit | Tier | Subject |
|--------|------|---------|
| 0cc68a2 | low | control-plane: fix darwin journal + systemd handlers, provider throttle |
| 3a7136a | low | gitops: darwin deployed-commit tracking + failure backoff |
| ab0e24d | low | host-status: darwin branch (launchd status.json writer) |
| c69182c | low | ci: force-evaluate darwinConfigurations in release checks |
| 0607ab1 | med | host.nix: host-status is a default aspect on darwin too |
| fd6bca2 | med | aspects: explicit Linux-only platform gates (14 aspects) |
| e7675ed | low | docs: darwin parity audit |

No high-tier commits: nothing on this branch changes what a Linux host
evaluates to (proven below), and the genuinely high-risk ideas (darwin
rollback, gitops mechanism merge beyond state-model convergence, upload on
darwin) were deliberately documented instead of attempted — they need
hardware or a decision (audit doc §4).

Cherry-pick notes: 0607ab1 (`[med]` host.nix) requires ab0e24d (`[low]`
host-status) or darwin eval breaks. Everything else is independent.

## Verification actually run (Linux dev sandbox; no Darwin hardware, no
deploys, no live-host mutations)

- `git diff main -- flake.lock '**/flake.lock'` → **empty** (root and all
  per-host/cluster lockfiles untouched).
- **drv-path comparison, all 13 NixOS hosts** (azula, doofenshmirtz,
  drhorrible, frankenstein, joker, lordhenry, minos, pettigrew, q, raishan,
  ratched, robotnik, ursula): evaluated
  `nixosConfigurations.<host>.config.system.build.toplevel.drvPath` from the
  branch working tree and from a `main` worktree — **all 13 IDENTICAL**
  (e.g. ratched `p7n5pb0rgh6ajmm3c9xjplrfhapk143r-nixos-system-ratched-…drv`
  on both). This covers low+medium tiers together and every gated aspect in
  actual use. Two intermediate regressions were caught and reverted this
  way (`meta` addition to fort-overlay-manager and the emergency-reboot
  gate, both `src = ./.` self-hash traps).
- `nix eval ./clusters/bedlam/hosts/obrien#darwinConfigurations.obrien.config.system.build.toplevel.drvPath`
  → evaluates cleanly (`7hy9w4vbkb5qp67wbi4zg3k9qb1w1r38-darwin-system-…drv`;
  differs from main as intended — new status daemon, updated handlers).
- `nix flake check --no-build` on the root flake, ratched's host flake, and
  obrien's host flake → all pass. (Noted: flake check does not deep-eval
  darwinConfigurations on Linux — hence the new CI step.)
- `go build ./...` + `go vet` + `go test ./...` in `pkgs/fort-provider`,
  `pkgs/fort-upload`, `pkgs/fort-tokens`, `pkgs/fort-overlay-manager` →
  build/vet clean; **no test files exist in any fort package** (pre-existing;
  `go test` reports "no test files").
- Aspect gate behavior: direct `nix-instantiate --eval` of gated aspects
  with `platform = "darwin"` → throws
  `fort-nix: aspect 'zfs' is Linux-only (…); remove it from this darwin
  host's manifest`; with `platform = "nixos"` → returns the module attrset.

## Needs Darwin hardware to verify (in suggested order, on obrien after cherry-pick)

1. `fort obrien status` — expect `status: "running"`, real uptime,
   `deploy.commit` populated after the first post-deploy gitops tick.
2. `fort obrien journal '{"unit":"fort-provider"}'` — expect log lines from
   `/var/log/fort-provider.log` (this was the empty-results bug).
3. `fort obrien systemd '{"action":"restart","unit":"fort-provider"}'`
   twice in quick succession — both should succeed (second used to hit the
   launchd throttle); response reports `"method": "bootstrap"`.
4. `fort obrien systemd '{"action":"list"}'` / `'{"action":"status","unit":"fort-gitops"}'`
   — label resolution for short names.
5. Push a commit, watch `/var/log/fort-gitops.log` — expect
   deployed-commit written on success; push a deliberately broken commit —
   expect backoff messages instead of a 30s retry storm.
6. Root-cause of q-d9b7ef7b (why the provider crashes at early boot) —
   `ThrottleInterval`/bootstrap fix the symptom; the boot-time log will show
   the cause.

Not attempted (documented in audit §4): darwin rollback on failed switch,
manualDeploy/deploy capability on darwin, test-branch gitops (absent on both
platforms in this repo), file upload to darwin hosts, attic push of darwin
closures.

---

# DONE — cert/ACME lifecycle hardening

Branch: `burn/cert-lifecycle` (from `main` @ 130968f). Nothing deployed;
no remote state touched; `flake.lock` untouched (`git diff main --
flake.lock` is empty).

## Summary

The pinned nixpkgs ACME module splits each cert into a marker-gated
self-signed bootstrap unit (`acme-<domain>.service`, exits 0 when
`out/acme-success` exists) and the real timer-driven lego renewal
(`acme-order-renew-<domain>.service`). fort-nix had its entire
re-distribution path — the ssl-cert push trigger and the broker's local
nginx copy — hooked to the bootstrap unit, so real renewals propagated
nowhere. On top of that, the generated `fort-provider-trigger-*` units had
no `path`, so even fired triggers lost every callback to an exec ENOENT on
the `fort` CLI while exiting 0. And consumers, once `satisfied=true`,
never re-requested — hence the manual force-nag ritual.

Fixes: renewal push moved to the ACME module's `postRun` hook (fires only
on actual renewal); trigger units got `path = [ fortCli ]` (also repairs
`oidc-register` pushes); a new opt-in `check` freshness probe in the needs
protocol lets a satisfied need decay and re-request (ssl-cert re-pulls
below 21 days validity — the pull-side backstop, no wire change); a broker
watchdog force-renews on actual expiry (marker explicitly ignored) and
fails loudly if the cert expires; the consumer install path now validates,
refuses downgrades/garbage, installs atomically, and reloads nginx only on
change; nginx's placeholder bootstrap also recovers from corrupt (not just
missing) cert files. All expiry/marker/install decisions live in a new
stdlib-only Go package, `pkgs/fort-certcheck`, as pure functions with unit
tests (no live CA needed).

Full walkthrough, blast-radius audit, and deferred proposals:
`docs/cert-lifecycle-audit.md`.

## Commits

- 090011a `[med] q-6f9d966e: pkgs/fort-certcheck — testable cert lifecycle decisions`
- e009736 `[med] q-6f9d966e: broker — push renewals via postRun, expiry watchdog`
- 7424222 `[med] q-5118c7ed: control plane — trigger PATH fix + check freshness probe`
- 972df4d `[med] q-b0530f9b: consumers — validated atomic cert install + freshness check`
- 960aa5d `[low] docs: cert lifecycle audit`

## Quest disposition

| Quest | Disposition |
|-------|-------------|
| q-6f9d966e | **Fixed.** Renewal decisions keyed on actual notAfter (`DecideRenewal` ignores the marker by design; `TestDecideRenewal_ExpiredCertWithStaleMarker` is the regression test). Broker watchdog force-starts `acme-order-renew` below 25d and fails visibly at expiry. Correct manual knob documented: `systemctl start acme-order-renew-<domain>.service`. |
| q-5118c7ed | **Fixed (safe subset) + proposal.** Push path repaired (postRun hook + trigger PATH); pull backstop via the new `check` probe on the ssl-cert need (re-requests under 21d validity, once per nag interval). Consumer-local only — wire protocol, callbacks, GC untouched. Deferred to proposal (audit §4): provider-side delivery tracking/retry and content-hash/notAfter in the fulfillment identity, both needing live two-host testing. Test covering fulfilled-but-stale: `TestIsFresh` + `TestShouldInstall_RenewedCertReplacesOld`. |
| q-b0530f9b | **Audited + worst wedges fixed.** Blast-radius writeup in audit §2. Fixed: malformed callback payload clobbering live certs (latent, would have broken TLS cluster-wide), corrupt cert wedging nginx at boot, silent renewal-path death (watchdog alarm). Everything now degrades to serve-stale + loud failed unit. |
| q-5c4502d3 | **Sketch only** (audit §4), per brief: not built. The per-domain request keying is additive and backward compatible when wanted. |

## Verification actually run

1. `go test ./...` in `pkgs/fort-certcheck` — pass (12 tests). Also runs
   in the nix build checkPhase (verified via `nix build` of the package)
   and added to `just test`.
2. CLI smoke test with openssl-generated certs (scratchpad): marker
   ignored on expired cert; 1-day placeholder → stale; 90-day → fresh;
   downgrade refused (rc=1); garbage / key mismatch refused (rc=3);
   real-over-placeholder accepted (rc=0).
3. `nix flake check ./clusters/bedlam/hosts/drhorrible` and `…/ratched` —
   pass.
4. Full `just test` (root flake + all 14 hosts + all devices in parallel,
   plus all Go provider suites) — exit 0.
5. drv-diff vs main (recursive derivation-graph set difference):
   - ratched: `p7n5pb0r…` → `jxb3yrhv…`; only intended drvs changed
     (fort-certcheck, ssl-cert-handler, ssl-cert-fresh, fort-fulfill,
     needs.json, fort-consumer units, nginx pre-start, roll-ups).
   - drhorrible: `9c2qvrab…` → `gk8wybqm…`; only intended drvs changed
     (watchdog units, acme-order-renew + acme-postrun, both
     fort-provider-trigger units, handler-ssl-cert, fort-fulfill,
     fort-certcheck, roll-ups).
   Closure changes are intended in every case; details in audit §3.
6. `git diff main -- flake.lock` — empty.

Not verified (needs live hosts, out of scope per brief): an actual
renewal→push→install round trip, and watchdog behavior against a real
wedged timer. The decision layer is unit-tested; the wiring is
eval-checked; first live renewal on a canary host (suggest `<host>-test`
branch on a consumer + `fort drhorrible systemd '{"action":"start","unit":"fort-provider-trigger-ssl-cert"}'`)
is the remaining prudent step before trusting it in anger.

## darwin-parity merge friction (unmerged `burn/darwin-parity`)

Overlapping files: `aspects/certificate-broker/default.nix` (parity adds a
platform-gate header, this branch edits the body — expect one trivial
take-both conflict at the file head) and `common/fort/control-plane.nix`
(disjoint hunks: parity touches the darwin journal handler and platform
gating; this branch touches needOptions / needsJson / fulfill script /
trigger generation — should auto-merge). The `check` probe runs unchanged
under parity's darwin launchd consumer (plain jq/coreutils store paths).
Details in audit §5.
