# DONE — Mobile e2e feedback loop (obrien muse serve + iOS agent loop)

Campaign Fable Weekend (c-f4e0eb4f), quest q-6c1fbe34. Date: 2026-07-12.
Model: Fable. All deliverables from BRIEF.md landed; no blockers remain for
the hearth-room live-fire, which is Kevin's to fire.

## Solved (with verification evidence)

1. **muse binary on obrien** — muse is pure Go; cross-compiled on ratched
   (`GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -mod=vendor`, muse repo
   @ 96cbf59) and installed manually at `/usr/local/bin/muse` (root-owned,
   0755). Verified: `muse --tools` and `muse serve` run on obrien.
   Declarative packaging noted as follow-up in the runbook (repo is
   `git.gisi.network/infra/muse` with vendored deps, so a `pkgs/muse`
   buildGoModule is tractable once darwin nix builds have forge fetch creds;
   overlays are Linux-only).

2. **muse serve as launchd daemon, declared in fort-nix** — obrien's
   `manifest.nix` now declares `launchd.daemons.muse-serve` (label
   `network.gisi.muse.serve`, RunAtLoad + KeepAlive, UserName=admin,
   `--addr 0.0.0.0:4600`) and `sops.secrets.muse-serve-token` (encrypted
   copy of ratched's `~/.config/cranium/obrien-muse.token`, decrypt
   roundtrip verified byte-identical before commit). Deployed via gitops
   (commits ac6c624, 250d94d, 88b8d2d, all flake-checked; ratched drvPath
   verified byte-identical to main for the shared-file changes).
   macOS Application Firewall is disabled on obrien — no socketfilterfw
   allowance was needed (documented in runbook for if it's ever enabled).

3. **Transport verified from ratched** (all three, this session):
   - `GET /healthz` with the cranium token → `{"ok": true}`
   - wrong token → HTTP 401
   - `POST /exec {"tool":"bash","input":{"command":"pwd && whoami"},"cwd":"/Users/admin/Projects/hearth"}`
     → 200, stdout `/Users/admin/Projects/hearth\nadmin`, exit_code 0

4. **Hearth source current on obrien** — `just sync` from
   `~/Projects/hearth` on ratched → `/Users/admin/Projects/hearth`.
   (Note: `just` needs `XDG_RUNTIME_DIR` overridden in this sandbox —
   `/run/user/0` is unwritable.)

5. **One full iOS loop cycle, demonstrated headless over ssh**:
   xcodebuild for simulator (BUILD SUCCEEDED) → `simctl boot "iPhone 17
   Pro"` → install → launch (`network.gisi.hearth`, pid 24244) → `simctl io
   booted screenshot` → 10s `log stream` sample. Screenshot pulled back to
   ratched and visually confirmed: Hearth chat UI (MAW `#roost` room)
   rendered. **The GUI-session concern did not materialize** — the whole
   loop ran with nobody logged in at the console (`/dev/console` owned by
   root) on macOS 26.2. Bonus e2e: a second screenshot was taken *through*
   `POST /exec` (the exact hearth-room call path), exit 0.
   Artifacts on obrien: `/Users/admin/artifacts/2026-07-12-muse-loop/`
   (`xcodebuild.log`, `hearth-launch.png`, `hearth-via-exec.png`,
   `log-stream-sample.txt`).

6. **Runbook** — `docs/obrien-muse-serve.md`: declarative vs. manual split,
   exact rebuild/reinstall commands, verification commands, the headless
   simctl loop, and every rough edge found.

## Fixed along the way (darwin-parity runtime findings, as predicted)

- **`pmset -a RestartAfterFreeze 1` fails on macOS 26.2** (usage error) —
  it was in the mac-mini profile's postActivation and killed **every**
  darwin activation at the last step. Verified manually (autorestart and
  womp succeed; RestartAfterFreeze does not); dropped it. (250d94d)
- **Darwin gitops ownership check used BSD `stat -f` with GNU coreutils
  first in PATH** — misfired and `chown -R`'d the repo every 30s poll.
  Pinned to `/usr/bin/stat`. (250d94d)
- **launchd opens Standard{Out,Error}Path as the daemon's UserName** —
  an admin-uid daemon pointed at `/var/log/x.log` fails to spawn at all
  (EX_CONFIG 78, zero log output, 73 silent retries). Fixed by pre-creating
  the log root-side at activation. (88b8d2d)

## Known open issue (ticketed, not blocking)

- **q-a54f7e19**: the darwin gitops daemon runs `darwin-rebuild switch`
  inline; when a commit changes the gitops daemon's own plist, activation's
  launchd-services step reloads it and kills its own in-flight rebuild —
  activation silently truncates (later steps incl. sops secrets never run)
  while `deployed-commit` claims success. Hit this live deploying 250d94d;
  recovered with `sudo /nix/var/nix/profiles/system/activate` (documented in
  the runbook). Proper fix needs the switch detached from the daemon's
  process group (no setsid/systemd-run on macOS → transient `launchctl
  submit` job or double-fork wrapper).

## Manual steps taken (all in the runbook)

1. Cross-compiled muse on ratched, scp'd, `sudo install` to
   `/usr/local/bin/muse` on obrien.
2. `just sync` of hearth from ratched.
3. One recovery `sudo /nix/var/nix/profiles/system/activate` on obrien
   (the q-a54f7e19 truncation).
4. One `launchctl bootout` + `bootstrap` of muse-serve to clear the stale
   EX_CONFIG last-exit code so host-status stops counting it failed
   (daemon was already healthy; healthz re-verified after).
5. Ran the iOS loop over ssh (commands in the runbook).

## What the hearth-room live-fire still needs

Nothing on the infrastructure side. Cranium's `hearth` profile resolves the
token per call and the endpoint answers with exactly that token, so a
message in the `hearth` room should execute on obrien as-is. Kevin fires it.

Notes:
- I attempted the sanctioned milestone ping via `muse --room hearth` — the
  auto-approval classifier denied it (external-write). Skipped rather than
  worked around; this file is the record.
- `fort obrien status` still says "degraded": the one remaining failed unit
  is Apple's `com.apple.iomfb_fdr_loader`, pre-existing and unrelated (plus
  a `"Label"` header artifact in the failed-units parser — cosmetic bug in
  the darwin systemd handler, noted for whoever next touches it).
- AXe was not brew-installed; `simctl` alone covered v1 per the brief.
