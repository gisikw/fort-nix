# obrien: muse serve + iOS agent loop

How obrien (Apple Silicon Mac mini, nix-darwin, gitops) is provisioned to act
as the exec backend for Cranium rooms — an agent on ratched posts tool calls
to `http://obrien.fort.gisi.network:4600` and they execute on obrien (Xcode
builds, simulator control, screenshots). Set up 2026-07-12 for quest
q-6c1fbe34; the live consumer is cranium profile `hearth` on ratched.

## Architecture

```
cranium (ratched, profile `hearth`)
  └─ POST /exec  Bearer <token>            http://obrien.fort.gisi.network:4600
       └─ muse serve (launchd daemon, runs as admin)
            └─ spawns `muse --exec ...` per request
                 └─ bash/read/write/... tools, incl. xcodebuild + simctl
```

- `muse serve` contract: see `docs/serve.md` in the muse repo. Bearer auth is
  mandatory and fails closed; `GET /healthz`, `GET /tools`, `POST /exec`.
- The URL and token path are baked into cranium's profile on ratched
  (`exec_endpoint.url`, `token_file: ~/.config/cranium/obrien-muse.token`).
  The port (4600) and hostname are therefore **hard constraints**.

## What is declarative (fort-nix)

All in `clusters/bedlam/hosts/obrien/manifest.nix`:

- **`launchd.daemons.muse-serve`** — label `network.gisi.muse.serve`,
  `RunAtLoad` + `KeepAlive`, runs as `admin` (system domain, so it is up
  without a GUI login), logs to `/var/log/muse-serve.log`, binds
  `0.0.0.0:4600`. Binding all interfaces (rather than the tailscale IP)
  keeps the daemon independent of tailscaled startup order; the bearer token
  is the access control, and the LAN is trusted. macOS Application Firewall
  is **disabled** on obrien (`socketfilterfw --getglobalstate` → 0), so no
  allowance was needed — if it is ever enabled, add
  `/usr/local/bin/muse` via `socketfilterfw --add`/`--unblockapp`.
- **postActivation log pre-create** — launchd opens `StandardOutPath` as the
  daemon's `UserName`, and `/var/log` is not admin-writable; without a
  root-side `touch`+`chown` of `/var/log/muse-serve.log` the spawn itself
  fails with `EX_CONFIG` (78) and no log is ever written.
- **`sops.secrets.muse-serve-token`** — `muse-serve-token.sops` next to the
  manifest, decrypted by obrien's host key to
  `/run/secrets/muse-serve-token`, owner `admin`, mode 0400. Content is
  byte-identical to `/home/dev/.config/cranium/obrien-muse.token` on ratched
  (the cranium side reads its copy per call, so rotating means: update the
  ratched file, re-encrypt into fort-nix, deploy obrien — no cranium
  restart).
- **`axe`** (`pkgs/axe`, in obrien's systemPackages) — HID-level simulator
  gestures for the loop; see § Gestures below. Packaged from the prebuilt
  universal release tarball (cameroncooke/AXe); obrien has no Homebrew and
  AXe is not in nixpkgs, so the release binary + its bundled FB frameworks
  are installed whole under `libexec` with a `bin/axe` exec shim
  (`dontStrip`/`dontFixup` — the shipped code signature must survive, and
  the frameworks resolve via `@executable_path`).

## What is manual (redo these if obrien is replaced)

1. **The muse binary** at `/usr/local/bin/muse`. muse is pure Go; built on
   ratched and copied over:

   ```bash
   cd ~/Projects/muse
   nix develop --command bash -c \
     'GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -mod=vendor -trimpath -ldflags="-s -w" -o /tmp/muse-darwin-arm64 .'
   sshpass -p '<admin pw>' scp /tmp/muse-darwin-arm64 admin@obrien.fort.gisi.network:/tmp/muse-new
   sshpass -p '<admin pw>' ssh admin@obrien.fort.gisi.network \
     'sudo install -m 755 -o root -g wheel /tmp/muse-new /usr/local/bin/muse && rm /tmp/muse-new'
   ```

   To pick up a new muse version, rebuild + recopy + `sudo launchctl kickstart
   -k system/network.gisi.muse.serve`. Follow-up for a declarative install:
   muse lives at `git.gisi.network/infra/muse` and vendors its deps, so a
   `pkgs/muse` derivation (`buildGoModule`/`go build -mod=vendor`) is
   tractable once the darwin nix build has forge fetch credentials; the
   overlay system is Linux-only today.

2. **Hearth source** at `/Users/admin/Projects/hearth` — synced from ratched
   with `just sync` in `~/Projects/hearth` (rsync over sshpass; `.env` there
   carries BUILD_USER/BUILD_PASS/BUILD_HOST).

3. **Xcode** — already present (`/Applications/Xcode-26.2.0.app`, selected via
   `xcode-select`). Managed outside this doc (xcodes is in systemPackages).

## Verification (from ratched)

```bash
TOKEN=$(cat ~/.config/cranium/obrien-muse.token)
# health (auth required even here)
curl -s -H "Authorization: Bearer $TOKEN" http://obrien.fort.gisi.network:4600/healthz
# → {"ok":true}
# wrong token → 401
curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer nope" \
  http://obrien.fort.gisi.network:4600/healthz
# exec
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"tool":"bash","input":{"command":"pwd"},"cwd":"/Users/admin/Projects/hearth"}' \
  http://obrien.fort.gisi.network:4600/exec
```

Diagnostics on obrien:

```bash
fort obrien journal '{"unit": "muse-serve", "lines": 50}'   # /var/log/muse-serve.log
fort obrien systemd '{"action": "status", "unit": "muse-serve"}'
```

## iOS loop over ssh (raw CLI, no muse required)

The same loop the hearth room drives via `/exec`, runnable by hand:

```bash
cd /Users/admin/Projects/hearth
# build for simulator
xcodebuild -project Hearth.xcodeproj -scheme Hearth -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
# find the built .app
APP=$(find ~/Library/Developer/Xcode/DerivedData -path '*Build/Products/Debug-iphonesimulator/Hearth.app' | head -1)
# boot + install + launch
xcrun simctl boot 'iPhone 17 Pro' || true   # already-booted is fine
xcrun simctl install booted "$APP"
xcrun simctl launch booted "$(defaults read "$APP/Info" CFBundleIdentifier)"
# see what it built
xcrun simctl io booted screenshot /tmp/hearth.png
xcrun simctl spawn booted log stream --level debug --timeout 10 \
  --predicate 'processImagePath CONTAINS "Hearth"'
```

## Gestures (AXe) — q-ee81198d

simctl cannot tap or swipe; `axe` (on PATH via systemPackages) injects HID
events into the booted simulator, headless, over ssh. Verified 2026-07-12 on
macOS 26.2 / iOS 26.2 simulators driving the Hearth drawer:

```bash
UDID=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
axe describe-ui --udid "$UDID"     # accessibility tree, frames in points
axe tap -x 201 -y 739 --udid "$UDID"   # tap center of an element's frame
axe swipe --start-x 201 --start-y 600 --end-x 201 --end-y 200 \
  --duration 0.5 --udid "$UDID"        # scrolls scroll views
axe type 'hello' --udid "$UDID"
```

Rough edges found (all verified live, not guesses):

- **`axe drag` does not work** on this stack: `FBSimulatorHIDEvent does not
  support touch move events`. No continuous-drag actuation (sheet handles,
  drag-and-drop).
- **`axe swipe` scrolls but does not drive drag-gesture UI** — it scrolled
  the Settings app fine, but had zero effect on Hearth's drawer sheet in
  either direction (same missing touch-move events). If a swipe silently
  does nothing, find a tappable control via `describe-ui` instead: the
  Hearth drawer opens by tapping its `Open Lair surface drawer` button and
  closes by tapping a surface card (tapping the dimmed background does not
  close it).
- Coordinates are points (iPhone 17 Pro: 402x874); screenshots are 3x pixels.

Demonstrated cycle: `/Users/admin/artifacts/2026-07-12-axe-gestures/` on
obrien (`01-drawer-closed.png`, tap at (201,739), `02-drawer-open.png`,
plus the open-drawer `describe-ui` JSON). The agent-facing command reference
lives in the `ios-loop` macro (hoard, version 2) — keep the two in sync.

**GUI-session caveat**: verified empirically 2026-07-12 that the *whole loop
works headless* — `/dev/console` was owned by root (nobody logged in at the
GUI) and `simctl boot`/`install`/`launch`/`io screenshot` all succeeded over
ssh on macOS 26.2. The Simulator *app* (visible window) would still need a
GUI login, but the agent loop doesn't use it. If `simctl boot` ever fails
with a CoreSimulatorService connection error, log a user in at the console
(or Screen Sharing) and retry.

First demonstrated cycle: artifacts in
`/Users/admin/artifacts/2026-07-12-muse-loop/` on obrien (`xcodebuild.log`,
`hearth-launch.png`, `hearth-via-exec.png` — that one taken *through*
`POST /exec` — and `log-stream-sample.txt`).

## Known rough edges found during setup (fixed)

- macOS 26.2 `pmset` rejects `RestartAfterFreeze`; it was in the mac-mini
  profile's postActivation and failed **every** darwin activation. Removed
  (commit 250d94d).
- Darwin gitops ownership check used `stat -f` with GNU coreutils first in
  PATH — misfired every poll. Pinned to `/usr/bin/stat` (commit 250d94d).
- launchd opens `Standard{Out,Error}Path` as the daemon's `UserName`; an
  admin-uid daemon pointed at `/var/log/<x>.log` fails to spawn entirely
  (`EX_CONFIG`, nothing in any log). Fixed for muse-serve by pre-creating
  the file at activation (commit 88b8d2d); worth remembering for any future
  non-root darwin daemon.
- The gitops self-reload fix (c38ec13) writes `deployed-commit` before the
  rebuild, so a failed activation still reports the commit as deployed in
  `fort obrien status` until the next divergence. Failure state does land in
  `/var/lib/fort-gitops/switch-failures`; check `/var/log/fort-gitops.log`
  when in doubt.

## Known open issue: activation truncated on gitops self-change

The darwin gitops daemon runs `darwin-rebuild switch` **inline**. When the
deployed commit changes the gitops daemon's own plist (script content,
PATH, …), activation's "setting up launchd services" step reloads
`network.gisi.fort.gitops`, which kills the daemon's process group — *its
own in-flight rebuild included*. Activation stops right there: later steps
(networking, power, **sops secrets**, later daemons) silently never run,
while `deployed-commit` (written before the rebuild) claims success.

Observed live deploying 250d94d. Recovery:

```bash
sudo /nix/var/nix/profiles/system/activate
```

(idempotent; completes the remaining steps). Proper fix is to detach the
switch from the daemon's process group — macOS has no `setsid(1)` /
`systemd-run` equivalent, so it likely means a transient `launchctl submit`
job or a small double-fork wrapper. Tracked in ko.
