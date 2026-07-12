# DONE — iOS loop phase 2: gesture actuation on obrien (AXe)

Quest q-ee81198d (Fable Weekend c-f4e0eb4f), follow-up to q-6c1fbe34.
Date: 2026-07-12. All acceptance criteria met; no blockers.

## What was done

1. **AXe 1.7.1 installed declaratively via nix** (commit `22cd9e5`, deployed
   by gitops). Preference order from the brief resolved as follows:
   - nix-darwin homebrew module: **rejected** — obrien has no Homebrew at
     all (`which brew` → nothing, no `/opt/homebrew`), and the module does
     not bootstrap brew itself. Installing Homebrew to get one formula would
     restructure obrien beyond what AXe needs.
   - nixpkgs: **not packaged** (checked; `axe`/`axel` hits are unrelated).
   - Chosen: **`pkgs/axe/default.nix`** — the repo's existing
     custom-derivation pattern (cf. `pkgs/zot`), fetching the prebuilt
     universal release tarball from cameroncooke/AXe. The binary + its
     bundled FB frameworks (FBSimulatorControl et al) install whole under
     `libexec/axe/` with a `bin/axe` exec shim; `dontStrip`/`dontFixup`
     preserve the shipped code signature (frameworks resolve via
     `@executable_path`, which is why a symlink or a re-signed tree would
     break). Wired into obrien's `systemPackages` in
     `clusters/bedlam/hosts/obrien/manifest.nix`.

2. **Gesture cycle demonstrated on Hearth** (headless, over ssh, nobody at
   the console). Artifacts in
   `/Users/admin/artifacts/2026-07-12-axe-gestures/` on obrien:
   - `01-drawer-closed.png` — fresh launch of network.gisi.hearth
   - `02-drawer-open.png` — after `axe tap -x 201 -y 739` on the
     `Open Lair surface drawer` button; THE LAIR drawer with Maw / Log /
     Questbook / Cupola / Discovery cards visible
   - `describe-ui-drawer-open.json`, `NOTES.txt`
   These were produced with the **deployed** system axe
   (`/run/current-system/sw/bin/axe`), not the scratch copy used for
   initial validation.

3. **Macro updated**: `~/Projects/hoard/macros/ios-loop.json` → version 2,
   new "Gestures (axe)" section (UDID lookup, describe-ui → tap-center
   workflow, swipe-for-scroll, type/button, verified limitations, Hearth
   drawer specifics). Self-contained; JSON validated with jq.

4. **Runbook updated**: `docs/obrien-muse-serve.md` — axe added to the
   "What is declarative" list, new "Gestures (AXe)" section with commands
   and rough edges.

## Findings / rough edges (all verified live)

- **`axe drag` does not work** on macOS 26.2:
  `FBSimulatorHIDEvent does not support touch move events`. No
  continuous-drag actuation is possible (sheet drag-handles, drag-and-drop).
- **`axe swipe` scrolls but cannot drive drag-gesture UI.** It scrolled the
  Settings app (screenshot-verified) but had zero effect on Hearth's drawer
  sheet in either direction — consistent with the missing touch-move events.
  The practical rule (now in the macro): if a swipe silently does nothing,
  find a tappable control via `describe-ui`.
- Hearth drawer semantics: opens by tapping the handle **button**; closes by
  tapping a surface card; tapping the dimmed background does not close it.
- Tap/type/button/describe-ui all work headless via CoreSimulator with no
  GUI session, same as the phase-1 loop.

## How it was verified

- Recipe validated before committing: derivation test-built **on obrien**
  (`nix build --impure --expr 'import /tmp/axe-drv.nix ...'`) and the store
  path ran `describe-ui` + a live tap successfully.
- `nix flake check ./clusters/bedlam/hosts/obrien` green before push
  (change is obrien-scoped: new `pkgs/axe/` + obrien manifest only).
- Post-deploy: `fort obrien status` shows commit `22cd9e5`; over ssh
  `which axe` → `/run/current-system/sw/bin/axe`, `axe --version` → 1.7.1.
  (obrien's one failed unit is `com.apple.iomfb_fdr_loader`, an Apple
  daemon, pre-existing and unrelated.)
- Consumer path proven: `POST /exec` to muse serve from ratched with
  `{"tool":"bash","input":{"command":"axe --version && which axe"}}` →
  `1.7.1`, `/run/current-system/sw/bin/axe`, exit 0 — hearth-room agents
  get axe on PATH with no muse changes.
- Both screenshots pulled back to ratched and visually inspected: 01 shows
  the chat with the drawer handle at bottom; 02 shows THE LAIR drawer open
  with all five surface cards. (The prior live-fire "LIVE-FIRE" label was
  not present — not chased, per brief.)

## Not done (deliberately)

- No credential hygiene (rotation ticketed separately, per brief).
- No Questbook quest closed — Kevin verifies manually.
- Homebrew not installed on obrien; its brew-less state is unchanged.
- `idb` fallback not needed — AXe covers tap/type/scroll; the drag
  limitation is a framework-level constraint documented in macro + runbook.
