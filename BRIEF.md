# BRIEF: iOS CI on obrien — darwin runner, apple-dist migration, hearth pipeline

You are working in `~/Projects/fort-nix` on ratched. Model: Fable-tier; this
lane is judgment-heavy (darwin/NixOS seam, no prior art in-repo for two of the
three pieces). All work on `main` in both repos; gitops is live — green pushes
deploy.

## Goal

Hearth (iOS app, repo `https://git.gisi.network/infra/hearth.git`) currently
builds through a bespoke local loop: a justfile on the dev box sshes into
obrien (the fleet mac mini), runs xcodebuild there, scps the IPA back, and
copies it into ratched's apple-dist directory. Replace that with real CI:

1. **A Forgejo Actions runner on obrien**, tagged as the iOS/macOS box.
2. **The `apple-dist` app moved from ratched to obrien** — the runner and the
   distribution endpoint belong on the same host so delivery is a local copy.
3. **A hearth CI workflow**: on push to main → build, sign, export ad-hoc
   IPA, publish IPA + manifest plist to apple-dist. Zero manual steps.

## Settled diagnosis (verified before dispatch — trust this, spot-check freely)

### obrien
- nix-darwin host, manifest at `clusters/bedlam/hosts/obrien/manifest.nix`
  (device profile `mac-mini`, platform darwin). Precedents that matter:
  - `fort.host.needs.git-token.dev` works on obrien → the control-plane
    needs/capability mechanism functions on darwin.
  - `launchd.daemons.muse-serve` is a working launchd daemon pattern there,
    including the `/var/log` pre-create workaround (read the comments — they
    encode real failure modes).
- ssh: `admin@obrien.fort.gisi.network`, password `exoiscool` (see
  `~/burn-night/OBRIEN.md`). Use
  `nix run nixpkgs#sshpass -- -p exoiscool ssh ...` from ratched.
- Signing assets already installed on obrien (verified):
  - `build.keychain-db`, unlock password `build`
    (`security unlock-keychain -p build ~/Library/Keychains/build.keychain-db`)
  - Identity: `Apple Distribution: Kevin Gisi (X2SQWVN3SV)`
  - Profiles in `~/Library/MobileDevice/Provisioning Profiles/`:
    `Hearth_AdHoc.mobileprovision`, `Hearth_Legacy_AdHoc.mobileprovision`
  - TEAM_ID `X2SQWVN3SV`, BUNDLE_ID `network.gisi.hearth`
- Xcode is installed and working (an agent built/tested Hearth in the
  simulator there all day today). `~/Projects/hearth` on obrien is a working
  clone, current with origin/main — but CI must check out fresh in its own
  workspace; do not point CI at that directory.

### ci-runner aspect (`aspects/ci-runner/default.nix`)
- **Throws on darwin by design.** Do not force it. Build the darwin
  equivalent: `forgejo-runner` daemon under launchd, running as `admin`
  (needs keychain + simulator access), registered against
  `https://git.gisi.network` via the same `fort.host.needs.runner-token`
  capability (provider: drhorrible, see `apps/forgejo/default.nix` ~line 359).
- Read the Linux aspect closely — it encodes the registration idempotency
  dance (`.runner` file id check), config.yml generation, and env plumbing
  (`ATTIC_*`, `FORT_SSH_KEY`) you'll want to mirror where applicable.
- Labels: register with labels that mark this as the macOS/iOS box —
  suggest `macos:host` and `ios:host` (match the existing `nixos:host` /
  `hoard:host` convention). The hearth workflow will target one of these.
- Decide whether this lives as a darwin-guarded aspect (e.g. the aspect
  branches on platform instead of throwing) or as a module in obrien's
  manifest. Prefer whichever the repo's conventions support most cleanly;
  an obrien-manifest module is acceptable for v1 (precedent: muse-serve).

### apple-dist (`apps/apple-dist/default.nix`)
- Currently in **ratched's** manifest (`clusters/bedlam/hosts/ratched/manifest.nix`).
- NixOS-flavored: `systemd.tmpfiles.rules` + `services.nginx.appendHttpConfig`
  (internal server on 127.0.0.1:8710) + `fort.cluster.services` entry:
  subdomain `apple`, visibility public, sso `{ mode = "identity"; groups = ["admin"]; }`.
- The index.html JS depends on **nginx autoindex JSON** at `/ipas/`
  (`autoindex_format json` — fields `name`, `mtime`). Whatever serves on
  darwin must preserve that contract (nginx from nixpkgs under launchd, or an
  equivalent that emits the same JSON — nginx is the low-risk path).
- **No darwin host currently declares `fort.cluster.services`.** This is the
  highest-uncertainty item. Investigate how the routing/gatekeeper layer
  resolves a service declaration to its host (start:
  `common/fort-options.nix`, `common/fort/overlays.nix`, core modules, the
  needs auto-generation mentioned in README). If the machinery is
  host-agnostic (relay proxies subdomain → declaring host:port), darwin
  should Just Work once obrien listens on the port (bind a reachable
  address, not 127.0.0.1, if the proxy is remote). If it is NOT
  host-agnostic, make the smallest honest change to the core machinery that
  lets a darwin host participate — and flag it prominently in DONE.md.
- **Migrate the existing artifacts**: copy the current contents of
  ratched:/var/lib/apple-dist/ipas/ (Hearth Legacy ipa/plist and anything
  else) to the new location on obrien BEFORE removing the app from ratched.
  Losing the legacy build is not acceptable — it is the household's installed
  fallback app.
- Keep subdomain `apple`, keep sso mode `identity` + groups `admin` exactly —
  the itms-services install flow works under the current auth semantics; do
  not change them.
- Data dir on darwin: choose a sane path (`/var/lib/apple-dist` may be fine
  on darwin if created via activation script; `/Users/Shared/apple-dist` is
  an acceptable alternative). Owner must allow the CI job (running as admin)
  to write IPAs in and nginx to read them.

### hearth CI workflow
- Repo: `infra/hearth`, main branch, tip today `c5af6ef`. There is a stale
  checkout at `/home/dev/Projects/hearth` on ratched — `git pull` it before
  editing; do NOT run `just sync` (it rsyncs over obrien's tree). Better:
  clone fresh in a scratch dir if in doubt.
- Existing `.forgejo/workflows/` examples in sibling repos (e.g.
  `~/Projects/coffer`, `~/Projects/cranium`) show house style.
- The justfile encodes the exact build recipe to translate. Workflow on push
  to main, `runs-on` the obrien label:
  1. Checkout.
  2. Simulator build + tests (`xcodebuild test` — HearthTests scheme). If
     tests are flaky in CI context, build-only is an acceptable gate for v1;
     say so in DONE.md.
  3. Unlock keychain, `xcodebuild archive` (Release, iphoneos, manual
     signing: identity `Apple Distribution`, profile `Hearth Ad-Hoc`,
     team `X2SQWVN3SV`).
  4. `xcodebuild -exportArchive` with an ad-hoc ExportOptions.plist
     (template is in the justfile `archive` recipe).
  5. Generate the manifest plist (template in the justfile `distribute`
     recipe; `DIST_URL=https://apple.gisi.network/ipas`).
  6. Copy `Hearth.ipa` + `Hearth.plist` into the apple-dist data dir
     (local copy — same box). Perms readable by the web server.
- Secrets posture: the keychain password (`build`) already appears in the
  hearth justfile, so keychain-unlock parity in the workflow is acceptable.
  Do not introduce NEW plaintext secrets into either repo; runner
  registration goes through the control plane, not committed tokens.
- Update the hearth justfile afterward: retire or clearly mark the bespoke
  ssh recipes that CI replaces (keep local-dev conveniences like `verify`
  if still useful); update README to describe the CI path.

## Hard constraints

- fort-nix and hearth mains only; push both when green.
- Do NOT break existing obrien services: muse-serve daemon, git-token need,
  installed packages. The hearth-room iOS loop depends on muse-serve.
- Do NOT touch obrien's `~/Projects/hearth` working tree or the simulator
  state beyond what CI runs require.
- Do NOT change ratched beyond removing `apple-dist` from its manifest (and
  only after artifact migration + obrien serving verified).
- Deploying: use the repo's standard deploy path for each host (justfile /
  gitops). For obrien you may ssh in and run the darwin-rebuild flow
  documented in the repo (bootstrap notes in justfile; config lives at
  /var/lib/fort-nix on the host or use the documented deploy target).
  If a ratched rebuild is needed to drop apple-dist, prefer the gitops path.
- No recursive greps/finds outside `~/Projects/fort-nix`, `~/Projects/hearth`,
  and scratch dirs. (Standing incident constraint.)
- If Anthropic 529s interrupt you, resume where you left off — commit early,
  commit often, so progress survives.

## Acceptance criteria

1. Forgejo shows an obrien runner, online, with the macOS/iOS labels
   (evidence: forge API or admin page screenshot/curl in DONE.md).
2. `https://apple.gisi.network` serves from obrien: page loads, SSO intact,
   legacy artifacts present and installable entries listed (evidence: curl
   headers/body from ratched + `ls -la` of the data dir).
3. End-to-end proof: push a small real commit to hearth main (docs-only is
   fine) → workflow triggers on the obrien runner → green → fresh
   `Hearth.ipa` + `Hearth.plist` land in the dist dir (evidence: workflow
   run id + log excerpt, before/after `ls -la --time-style=full-iso` of the
   dist dir, page JSON showing new mtime).
4. ratched no longer carries apple-dist (manifest diff in DONE.md).
5. All commits pushed; `git status -sb` clean in both repos at finish.
6. DONE.md in fort-nix root: what shipped, evidence per criterion above,
   any core-machinery changes flagged loudly, punts/seams listed, and the
   exact runbook for re-registering the runner if obrien is rebuilt.

Kevin-gated (do NOT attempt): installing the new build on a physical phone.
Note it in DONE.md as the human verification step.
