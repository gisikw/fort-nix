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
