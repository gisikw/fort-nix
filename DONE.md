# DONE: iOS CI on obrien — darwin runner, apple-dist migration, hearth pipeline

Work order: `BRIEF.md`. All three pieces shipped and verified end-to-end on
2026-07-16. fort-nix commits `67eded8..752fab9`, hearth commits
`af48922..c216145` (both mains, pushed, clean).

## What shipped

### 1. Forgejo Actions runner on obrien (darwin)

`aspects/ci-runner/default.nix` grew a darwin branch (it used to `throw`):

- `forgejo-runner` as a launchd daemon (`network.gisi.fort.ci-runner`),
  running as `admin` (keychain / simulator / provisioning-profile access),
  `KeepAlive`, logs to `/var/log/ci-runner.log`.
- Registered against `https://git.gisi.network` via the existing
  `runner-token` need (provider: drhorrible), same `.runner`-id idempotency
  dance as the Linux handler, labels **`macos:host` + `ios:host`**.
- `config.yml` rewritten every activation; job PATH = nix tools
  (bash/coreutils/git/jq/curl/tar/gzip/**nodejs** — required by
  actions/checkout) + `/usr/bin:/bin:/usr/sbin:/sbin` for the Apple
  toolchain.
- Provisions a **loopback ssh key** (`/var/lib/ci-runner/selfssh`, authorized
  for admin) — see "codesigning security session" below.

### 2. apple-dist moved ratched → obrien

- `apps/apple-dist/default.nix` now branches on platform; darwin uses an
  activation script for the admin-owned data dir and contributes the same
  nginx backend (static index + `/ipas/` autoindex JSON — the `name`/`mtime`
  contract the page JS needs) via the new `fort.darwin.nginxExtraHttpConfig`.
- Artifacts migrated **before** cutover: Hearth, HearthLegacy, Punchlist
  (ipa + plist each) copied to `obrien:/var/lib/apple-dist/ipas`, verified,
  then `apple-dist` removed from ratched's manifest (`bd38155`).
- Subdomain `apple`, `visibility = public`, `sso = { mode = "identity";
  groups = ["admin"] }` — unchanged, as required.

### 3. Hearth CI pipeline (`.forgejo/workflows/build.yml`)

Push to hearth main → on the obrien runner (`runs-on: macos`):

1. checkout → 2. **simulator build gate** → 3. `xcodebuild archive`
(Release, manual signing, `Apple Distribution` / `Hearth Ad-Hoc` /
`X2SQWVN3SV`) → 4. `-exportArchive` (ad-hoc ExportOptions) → 5. manifest
plist generation (`DIST_URL=https://apple.gisi.network/ipas`) → 6. local
`cp` of `Hearth.ipa` + `Hearth.plist` into `/var/lib/apple-dist/ipas`,
mode 644. Zero manual steps.

justfile: `archive`/`distribute`/`build-device` ssh recipes retired
(pointer comments remain); local conveniences (`verify`, `validate`,
`test`, `sync`) kept; `distribute-legacy` kept as break-glass and
repointed to drop artifacts on the build host. README + `.env.example`
updated.

**Test-gate note (BRIEF §workflow step 2):** the `HearthTests` scheme was
removed with the legacy app (per hearth README) — there is nothing to
`xcodebuild test`. The gate is the simulator build; re-add a test step when
a test scheme exists again.

## ⚠️ Core-machinery changes (flagged per brief)

The routing layer was **not** host-agnostic: the beacon proxies
`https://<declaring-host>:443` (SNI) and SSO is enforced by the declaring
host — but on darwin, `fort-provider` itself owned 0.0.0.0:443, and VPN
clients resolve service FQDNs straight to the declaring host's :443.
The smallest honest change that lets a darwin host participate with
identical semantics (public edge, VPN-direct with transparent tailscale
whois auth — which the itms-services install flow for household phones
depends on, LAN):

1. **`common/fort/darwin-services.nix` (new)** — when a darwin host declares
   `fort.cluster.services`: nginx on 443 under launchd (per-service TLS
   vhosts, identity SSO via identity-proxy socket, real cert via the
   `ssl-cert` need with a launchctl-flavored handler, placeholder certs at
   activation), plus the `proxy` / `dns-headscale` / `oidc-register` needs a
   NixOS host would auto-generate. Only `sso.mode = none|identity` is
   supported (asserted, not silently wrong).
2. **`common/fort/control-plane.nix`** — darwin `fort-provider` binds
   `127.0.0.1:8444` instead of `0.0.0.0:443` when services are declared;
   nginx proxies `/fort/` to it, so the fort CLI/callback contract
   (`https://<host>.fort.<domain>/fort/...`) is unchanged either way.
   Also anchored `WorkingDirectory=/var/lib/fort`.
3. **`pkgs/identity-proxy`** — tailscaled socket path is now
   `TAILSCALED_SOCKET`-configurable (darwin: `/var/run/tailscaled.socket`;
   Linux default unchanged). Without this, VPN whois auth would 401 on
   darwin and phones would hit a login wall on install.
4. **`devices/linode-85962061/manifest.nix` — raishan pubkey corrected** to
   the live host key (verified via `read-file` of
   `/etc/ssh/ssh_host_ed25519_key.pub`; the manifest held a
   pre-reprovision key). This was a **pre-existing cluster-wide breakage**:
   every raishan→consumer callback and GC query failed signature
   verification (all `dns-headscale-*`/`proxy-*` needs cluster-wide were
   stuck re-nagging hourly; orphaned provider state was unGCable — which
   would have left a stale `apple.gisi.network → ratched` DNS record
   breaking VPN installs ~50% of the time). **Deliberately did NOT run
   `just rekey`**: granting the corrected key access to sops secrets is an
   access-control change for human review → **ticket q-88cad98f** (raishan
   cannot decrypt freshly-rekeyed secrets until then, which was already the
   case). Original diagnosis ticket q-a48dcddb (closed).

### Codesigning vs. launchd security sessions (the big darwin gotcha)

The runner daemon lives in launchd's **System security session**, where the
signing identity fails trust evaluation: `security find-identity -v` reports
**0 valid identities** for the exact keychain that shows **1 valid** over
ssh (certs not expired; WWDR + root present; search list correct;
`set-key-partition-list` doesn't help; `sudo login -f` does **not** escape
the session — all verified empirically in runs 8059–8065). sshd-created
sessions were the context the old ssh build flow always used, so the fix is
honest: the ci-runner aspect provisions a loopback key and the workflow
wraps `xcodebuild archive`/`-exportArchive` in
`ssh -i /var/lib/ci-runner/selfssh admin@localhost`. No new plaintext
secrets (the key never leaves obrien; keychain password `build` was already
in-repo per the brief).

## Evidence per acceptance criterion

### AC1 — runner online with macOS/iOS labels

Registration (`/var/log/ci-runner.log`):
```
level=info msg="runner: obrien-runner, with version: v12.7.2, with labels: [macos ios], ephemeral: false, declared successfully"
level=info msg="[poller] launched"
```
Execution (forge CI log, run 8066): `obrien-runner(version:v12.7.2)
received task ... of job build, be triggered by event: push`. (The
admin-runners REST endpoint 404s on this Forgejo; the run log is the
authoritative liveness proof.)

### AC2 — https://apple.gisi.network serves from obrien, SSO intact

Via the public edge (raishan) from ratched:
```
$ curl -sk --connect-to apple.gisi.network:443:172.232.14.156:443 -I https://apple.gisi.network/
location: https://apple.gisi.network/_identity/login?rd=https://apple.gisi.network/   (302 — gatekeeping intact)
x-fort-host: obrien          ← served by obrien
x-fort-hop-raishan: 1        ← traversed the beacon
```
Direct (VPN source, whois path): `403` — my mesh identity resolves to a
non-`admin` user, i.e. group enforcement works; admin household devices get
transparent whois auth. TLS: real Let's Encrypt `CN=gisi.network` (ssl-cert
need delivered, `fresh: certificate valid for 1497h`).

Data dir + autoindex contract on obrien (post-e2e):
```
-rw-r--r--  1 admin  staff  1492591 Jul 16 15:57:49 2026 Hearth.ipa
-rw-r--r--  1 admin  staff      813 Jul 16 15:57:49 2026 Hearth.plist
-rw-r--r--  1 admin  staff   675408 Jun 26 22:56:36 2026 HearthLegacy.ipa
-rw-r--r--  1 admin  staff      837 Jun 26 22:56:36 2026 HearthLegacy.plist
-rw-r--r--  1 admin  staff   278230 Mar 20 09:07:48 2026 Punchlist.ipa
-rw-r--r--  1 admin  staff      822 Mar 20 09:07:48 2026 Punchlist.plist
```
`/ipas/` returns autoindex JSON with `name`/`mtime` — page JS contract
preserved. Legacy artifacts intact (the installed-fallback constraint).

### AC3 — end-to-end proof

Real commit `c216145` (workflow + docs) pushed to hearth main → run **8066**
on obrien-runner → green:
```
20:57:39 simulator build ok
20:57:48 archive ok
20:57:49 export ok
20:57:49 published c216145 to https://apple.gisi.network/ipas
20:57:49 🏁  Job succeeded
```
Before: `Hearth.ipa 833046 bytes, Jul 2 09:59`. After: `1492591 bytes,
Jul 16 15:57:49`. Autoindex JSON mtime: `Thu, 16 Jul 2026 20:57:49 GMT`.

### AC4 — ratched no longer carries apple-dist

Commit `bd38155`:
```diff
   apps = [
     "vdirsyncer-auth"
     "radicale"
-    "apple-dist"
     "conduit"
```
Deployed (ratched at `bd38155`+); stale beacon proxy/DNS state for
ratched:apple GC'd after the raishan key fix; `apple.gisi.network`
headscale record now points only at obrien (100.101.0.7).

### AC5 — clean repos

`git status -sb` clean and pushed in both fort-nix and hearth at finish
(this DONE.md + AGENTS.md update are the final fort-nix commit).

## Runbook: re-registering the runner if obrien is rebuilt

1. Bootstrap obrien per the justfile darwin flow; gitops then converges the
   config (runner daemon, config.yml, selfssh key, dirs are all declarative).
2. Registration is automatic: the `runner-token` need (nag 5m) fetches a
   token from drhorrible and registers as `obrien-runner`. If the forge
   shows the runner offline/stale: on obrien remove
   `/var/lib/ci-runner/.runner`, then
   `fort obrien force-nag '{"pattern": "runner-token"}'` — the handler
   re-registers and kickstarts the daemon.
3. **Signing assets are NOT nix-managed** and must be restored by hand on a
   rebuilt box: `~/Library/Keychains/build.keychain-db` (unlock password
   `build`), profiles in `~/Library/MobileDevice/Provisioning Profiles/`
   (`Hearth_AdHoc`, `Hearth_Legacy_AdHoc`), identity
   `Apple Distribution: Kevin Gisi (X2SQWVN3SV)`, plus Xcode itself.
4. Do **not** use `fort obrien systemd '{"action":"restart"}'` on launchd
   daemons — it boots the service out permanently (q-410f4bd6); recovery is
   a plist-changing commit or reboot.

## Punts / seams

- **LAN DNS (`dns-coredns`)** not generated on darwin: the coredns provider
  resolves origins via the `lan-ip` capability, which only the NixOS mesh
  aspect exposes. LAN clients resolve `apple.gisi.network` via the public
  wildcard and hairpin through the beacon — same auth semantics, small
  latency cost. Fix = tiny darwin `lan-ip` provider if it ever matters.
- **SSO modes on darwin**: only `none`/`identity` (asserted). oauth2-proxy /
  token-mode / staticRoot / egress services are NixOS-only for now.
- **CI test step**: simulator build is the gate (no test scheme exists).
- **Runner extras**: no attic/`FORT_SSH_KEY`/postgres plumbing on the darwin
  runner — nothing iOS builds need today; add when a workflow does.
- **`fort <host> systemd restart` darwin bug** — q-410f4bd6 (bit me during
  this work: it killed obrien's fort-provider; recovered via the `752fab9`
  plist-delta rebuild).
- **raishan sops rekey** pending human review — q-88cad98f.
- **`fort drhorrible ci` status labels** are unreliable for finished runs
  (reports `skipped` for both failed and succeeded runs; read the log).
- **fort-provider GC races the live daemon** — q-7793a008 (pre-existing,
  surfaced here): `--gc` edits `provider-state.json` on disk while the
  daemon re-saves dirty in-memory state on the next request, resurrecting
  GC'd entries. Workaround used for the apple cutover: GC → restart
  fort-provider → re-nag the consumer.
- Cosmetic: obrien `status` shows `degraded` due to Apple system launchd
  noise (`com.apple.iomfb_fdr_loader`, pre-existing) plus
  `network.gisi.fort.ci-runner` listing a stale last-exit-status (-15) from
  the registration kickstart — the daemon is alive and taking jobs; darwin's
  `failed` action reads `launchctl list` exit codes, which persist across
  restarts.

## Human verification step (Kevin-gated, per brief)

Install the fresh build on a physical phone: open
`https://apple.gisi.network` on the device (VPN + admin group → transparent
auth), tap **Install** on Hearth (mtime 2026-07-16). Not attempted from
here by design.
