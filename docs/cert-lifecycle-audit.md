# Certificate Lifecycle Audit

Branch: `burn/cert-lifecycle`. Covers quests q-6f9d966e (stale-marker
renewal), q-5118c7ed (consumers ignore renewals), q-b0530f9b (expiry
resilience), q-5c4502d3 (arbitrary-domain broker — sketch only).

## 1. Current-state walkthrough (issue → distribute → renew → re-distribute)

### Issue

The broker host (drhorrible, `certificate-broker` aspect) declares
`security.acme.certs.<domain>` with wildcard SANs (`*.<domain>`,
`*.fort.<domain>`), DNS-01 via the provider credentials in
`dns-provider.env.sops`. The pinned nixpkgs ACME module splits this into
**three units per cert**, which is the detail everything else in this audit
hangs on:

| Unit | Role |
|------|------|
| `acme-setup.service` | directories/permissions |
| `acme-<domain>.service` | "Ensure certificate": generates a **self-signed** bootstrap cert via minica so dependents can start. **Short-circuits (`exit 0`) if `out/acme-success` exists.** `RemainAfterExit=true`. |
| `acme-order-renew-<domain>.service` | The real lego run. Driven by `acme-order-renew-<domain>.timer` (daily). lego renews when < `validMinDays` (30) remain. On an actual renewal it touches `out/renewed`; `ExecStartPost` then runs `postRun` and `reloadServices`. Touches `out/acme-success` after any successful order. |

Certs land in `/var/lib/acme/<domain>/{fullchain,key,chain}.pem`.

### Distribute

- Broker: `fort-ssl-local-copy.service` copies ACME certs to
  `/var/lib/fort/ssl/<domain>` for the broker's own nginx (the ACME dir is
  not read directly by nginx).
- Cluster: the `ssl-cert` capability (async/aggregate) base64-encodes the
  three PEMs and returns the same payload for every consumer key
  (`origin:ssl-cert-default`). Consumers declare
  `fort.host.needs.ssl-cert.default` (every nginx host that isn't the
  broker); `fort-fulfill` requests it, gets HTTP 202, and the provider
  pushes the payload to each consumer's callback endpoint
  (`/fort/needs/ssl-cert/default`), where the consumer handler installs the
  files and reloads nginx. The provider re-pushes to **all** consumers on
  boot (`triggers.initialize`), and to consumers whose response **changed**
  on capability triggers.
- New consumers bootstrap with a 1-day self-signed placeholder (nginx
  `preStart`) so nginx can start before the real cert arrives.

### Renew / re-distribute — where it broke

Renewal is `acme-order-renew-<domain>.timer` → lego. Re-distribution was
hooked to **the wrong unit**: both the `ssl-cert` capability trigger and
`fort-ssl-local-copy` fired on `OnSuccess` of `acme-<domain>.service` — the
marker-gated bootstrap unit that does not run on renewal. And even when
that trigger did fire (e.g. an operator restarting the unit), the generated
`fort-provider-trigger-ssl-cert.service` had no `path`, so its callback
dispatch (`exec.Command("fort", ...)`) failed with ENOENT on every callback
while the unit exited 0.

**Net effect before this branch: no renewal was ever pushed to consumers
or even to the broker's own nginx by the renewal path.** Fresh certs
propagated only via provider boot/restart (initialize re-push) or manual
`force-nag` per host — matching the observed operational pain in
q-5118c7ed. The trigger PATH bug also affected `oidc-register` pushes on
the identity host (same generated unit shape).

## 2. Failure modes and fixes

### q-6f9d966e — renewal short-circuits on the acme-success marker

`systemctl restart acme-<domain>.service` deactivates the unit (firing
`OnSuccess` → pushes the **old** cert) and re-runs a script whose first
action is `[ -e out/acme-success ] && exit 0`. Exit 0, nothing renewed.
The marker means "a real cert was obtained at least once", not "the cert
is valid" — gating any renewal-ish behavior on it is the bug. The correct
manual renewal knob is `systemctl start acme-order-renew-<domain>.service`
(lego decides by actual expiry; the marker is irrelevant to it).

**Fixed (gate on actual expiry, per the ticket's preferred direction):**

- `pkgs/fort-certcheck` — Go package holding the decision logic as pure
  functions (`DecideRenewal`, `IsFresh`, `ShouldInstall`, `ValidatePair`),
  unit-tested without a live CA (self-signed certs generated in-test).
  `DecideRenewal` accepts the marker as input and **ignores it by
  design**; `TestDecideRenewal_ExpiredCertWithStaleMarker` is the
  regression test for this quest.
- `fort-cert-renewal-watchdog.{service,timer}` on the broker (every 6h):
  if < 25 days remain (below lego's 30, so it only fires after the normal
  timer path has failed for ~5 days), force-start
  `acme-order-renew-<domain>.service`; if the cert is expired outright and
  renewal didn't recover it, the unit **fails**, surfacing in
  `systemctl --failed`, `fort <host> status`, and observability.

### q-5118c7ed — renewed cert never reaches consumers

Three compounding causes, three fixes:

1. **Wrong hook**: renewal push moved to
   `security.acme.certs.<domain>.postRun` — the module's designed renewal
   hook, which runs only when lego actually installed a new cert. It
   `--no-block` starts `fort-ssl-local-copy` (broker nginx) and
   `fort-provider-trigger-ssl-cert` (cluster push). The old
   `acme-<domain>.service` trigger stays for the bootstrap/deploy path.
2. **Dead callback dispatch**: generated trigger units now carry
   `path = [ fortCli ]`. (NixOS only sets a unit's `Environment=PATH` when
   `path != []`; without it the `fort` shell-out died on exec.)
3. **No pull-side recovery**: needs gain an optional `check` script — a
   freshness probe run on every fulfill cycle while the need is satisfied.
   A failing probe flips the need to unsatisfied so the normal nag flow
   re-requests (once per nag interval, not per 5-minute cycle). The
   ssl-cert need uses `fort-certcheck fresh --min-days 21`: consumers
   re-pull automatically when their cert drops below 21 days, covering
   pushes lost to consumer downtime, network partitions, or future
   regressions in the push path. Threshold ordering: lego renews at 30d,
   watchdog forces at 25d, consumers demand 21d — consumers only nag when
   the broker has already had ≥4 days to renew.

   Consumer re-requests always produce a fresh callback: the provider
   clears the cached response when it records an incoming request
   (`recordProviderRequest`), so the re-computed response always registers
   as "changed". This is why force-nag worked as the manual workaround,
   and why the check-probe converges.

Protocol-safety: everything here is consumer-local or broker-local. The
wire format, callback semantics, GC rules, and fulfillment-state schema
are unchanged (`check` is a new optional field in the host-local
`needs.json`; the Go provider ignores unknown fields). See §4 for the
protocol-level alternatives considered and deferred.

One accepted wart: when a check fails, the fulfill script flips
`satisfied` in the state file mid-run (read-modify-write of just that
key). The end-of-run merge prefers the file's `satisfied=true` (protection
for callbacks landing mid-run), which would otherwise undo the flip. A
callback that races the flip re-marks the need satisfied — which is
correct, since a delivery just arrived and the next cycle re-probes it.

### q-b0530f9b — expiry blast radius

What actually happens when the wildcard cert expires, in order:

1. **Nothing crashes.** nginx (broker and consumers) starts and serves the
   expired cert; clients get trust errors. Control-plane calls (`fort`
   CLI → nginx on consumers) keep working because the CLI skips TLS
   verification (`curl -sk`; authenticity comes from ed25519 request
   signing) — so cert distribution itself survives cert expiry, which is
   what lets the self-healing below work. Browser-facing services all
   break at once.
2. **The broker held the only renewal path** (daily timer). If it wedged,
   nothing noticed: `acme-<domain>.service` stayed green (marker),
   `systemctl --failed` stayed empty, and the cert aged out silently.
   → Fixed: watchdog fails loudly at expiry (see q-6f9d966e).
3. **Consumers could not recover without manual help** even after the
   broker renewed (push broken, pull disabled by `satisfied=true`).
   → Fixed: postRun push + trigger PATH + check probe.
4. **Worst wedge found (latent):** the consumer handler piped
   `jq -r '.cert' | base64 -d` straight into the live cert files. A
   malformed or empty callback payload — e.g. the provider's revocation
   path POSTs `{}` — would decode the literal string `null` into 4 bytes
   of binary garbage, clobbering all three PEMs on every consumer. nginx
   keeps serving from memory until reload/reboot, then refuses to start.
   → Fixed: payload shape validated; decode to a same-filesystem scratch
   dir; `fort-certcheck should-install` gates on parse + key-match +
   no-downgrade (replayed older certs refused); rename into place; reload
   only on actual change (no more hourly reload churn); unusable payloads
   exit 1 so the need stays unsatisfied and delivery retries.
5. **Second wedge (boot-time):** nginx `preStart` generated a placeholder
   only when `fullchain.pem` was *missing*. A corrupt/truncated cert file
   (see #4, or a crash mid-write) wedged nginx permanently.
   → Fixed: placeholder regenerates when the cert is missing **or
   unparseable**. Expired-but-parseable certs are deliberately left in
   place: serving stale beats serving self-signed (stale is at least valid
   for pinned/legacy clients and keeps SAN coverage).
6. `fort-ssl-local-copy` on the broker already validated the source cert
   and falls back sanely (valid existing copy → keep; nothing valid →
   self-signed placeholder). Unchanged apart from now being triggered on
   real renewals.

Degradation order after this branch: cert nearing expiry → watchdog
force-renews and alerts at 25d; consumers self-heal at 21d; at actual
expiry everything **serves stale** (nothing wedges, nothing refuses to
start) with a failed watchdog unit as the standing alarm.

Pre-existing, noted not changed: `key.pem` under `/var/lib/fort/ssl` is
world-readable (`go=rX`), matching the previous handler's permissions. Any
tightening should be its own change with an inventory of non-root readers
(nginx workers, oauth2-proxy, identity-proxy).

## 3. Verification record

- `go test ./...` in `pkgs/fort-certcheck` — pass (also runs inside the
  nix build's checkPhase, and `just test` now includes it).
- CLI smoke-tested against openssl-generated certs: marker ignored,
  1-day placeholder stale, downgrades/garbage/key-mismatch refused with
  distinct exit codes (0/1/3).
- `nix flake check` per-host for drhorrible (broker) and ratched
  (consumer); full `just test` (all hosts, all devices, all Go provider
  suites) — exit 0.
- `git diff main -- flake.lock` — empty.

### drv-diff vs main

ratched (consumer), toplevel
`p7n5pb0rgh6ajmm3c9xjplrfhapk143r-…` → `jxb3yrhvpzqaq61qavicv4jzqvkh0011-…`.
New/changed drvs (full recursive graph diff, 5496 → 5498 drvs):
`fort-certcheck-0.1.0`, `ssl-cert-handler`, `ssl-cert-fresh`,
`fort-fulfill` (+ `needs.json`, fort-consumer units, restart-trigger),
`unit-script-nginx-pre-start` (+ nginx unit), and the `etc`/`system-units`/
toplevel roll-ups. All intended; nothing else moved.

drhorrible (broker), toplevel
`9c2qvrab2v3ivi62yllifmgnf84y8bh6-…` → `gk8wybqm09r1yaa87547aqfnhai63dxa-…`.
New/changed: watchdog service+timer, `acme-order-renew-gisi.network`
service + `acme-postrun` (postRun hook), `fort-provider-trigger-ssl-cert`
**and** `fort-provider-trigger-oidc-register` (both pick up the PATH fix),
`handler-ssl-cert` (notAfter field), `fort-fulfill`/fort-consumer,
`fort-certcheck`, roll-ups. All intended.

## 4. Proposals (not implemented)

**Provider-side delivery tracking.** Push callbacks remain fire-and-forget:
`sendCallback` logs failures and the provider marks the response current,
so a push lost to a down consumer is never retried (until the next boot
initialize). The check probe papers over this for certs (bounded staleness
of `fresh-threshold − delivery time`), but the general fix is a
`delivered: bool` per state key: mark false on dispatch failure, retry
undelivered keys from the hourly GC sweep (or a dedicated timer). Needs
live testing of the retry/GC interaction (revocation callbacks
intentionally send empty payloads and must not be retried as deliveries) —
deferred per the brief's no-YOLO rule.

**Fulfillment identity carrying content (`notAfter`/content-hash).** The
brief's suggested shape — putting the response hash or notAfter into the
fulfillment identity so a renewed cert structurally invalidates
`satisfied` — would generalize the check probe to every capability: the
consumer stores `response_hash` at callback time, and the provider's
`/fort/needs` GC responses (or a lightweight HEAD-style capability call)
let consumers compare hashes without transferring payloads. It touches the
callback handler (Go), fulfillment-state schema, and the GC protocol
contract, so it needs a live two-host test. The `ssl-cert` response now
carries `notAfter` explicitly to make that future change cheap and
observable. The check probe is the safe subset: same convergence property
for the cert case, zero wire change.

**q-5c4502d3 — arbitrary-domain certs (stretch, sketch only).** The
refactor points this branch creates:

- `security.acme.certs` already accepts multiple certs; the broker aspect
  could take a parameterized list
  (`{ name = "certificate-broker"; domains = [ … ]; }`) and generate a
  cert + postRun + watchdog per domain (`fort-certcheck` is
  domain-agnostic).
- The `ssl-cert` handler currently ignores the request payload and returns
  the wildcard to everyone. Extend the need's `request` to
  `{ domain = "example.org"; }` and key the aggregate handler's response
  per requested domain. Because the request is part of the state key and
  its hash is tracked consumer-side, existing wildcard consumers
  (`request = {}`) are untouched — additive and backward compatible.
- Consumer side: `fort.host.needs.ssl-cert.<name>` per extra domain with
  the same handler/check parameterized by target directory.
- RBAC: per-domain `allowed` lists on the capability if some domains
  shouldn't be cluster-readable.

Not built: no current consumer, and it multiplies the ACME failure surface
(per-domain DNS creds, rate limits) that this branch just finished
containing.

## 5. darwin-parity overlap (`burn/darwin-parity`, unmerged)

`git diff main...burn/darwin-parity --name-only` intersects this branch on:

- `aspects/certificate-broker/default.nix` — parity adds a 4-line
  Linux-only platform gate at the top (`deviceProfileManifest` arg +
  `throw`); this branch edits the body. Textually adjacent at the file
  head (the `let` binding area) — expect a trivial conflict; resolution is
  "take both" (gate on top, new body below).
- `common/fort/control-plane.nix` — parity edits the darwin journal
  handler (~line 270) and platform-gating around units; this branch edits
  needOptions (~line 940), needsJson (~line 1070), fortFulfillScript
  (~line 1150), and the trigger-service generation (~line 1600). Disjoint
  hunks; should merge cleanly. One semantic (not textual) note: parity's
  darwin consumer runs the same `fortFulfillScript` via launchd — the
  `check` probe logic is plain jq/coreutils via nix store paths and works
  there unchanged.
- `common/host.nix`, other aspects, CI workflow — untouched here.

Whichever branch merges second rebases through one small conflict in the
broker aspect header; no behavioral interaction.
