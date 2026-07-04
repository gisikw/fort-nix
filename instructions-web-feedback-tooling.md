# Dispatch: Agent visual feedback loop for web work (dev sandbox)

**Context:** Agents doing frontend work (Questbook SPA now; every web project
after) currently have no way to *see* their work — no browser, no screenshots,
no end-to-end inspection from the dev sandbox. "Fix the weird UI bugs" is
impossible when the only QA loop is Kevin's eyeballs. This is generic
infrastructure, not Questbook-specific.

## Goal

An agent in the dev sandbox can, with tools already on PATH:

1. Load a URL (local dev server or deployed, e.g. qb.gisi.network) in a real
   headless browser.
2. Take a screenshot at a chosen viewport size (desktop + mobile widths) and
   read it back (agents can read image files — PNG on disk is sufficient).
3. Get the rendered DOM/accessibility tree and console errors as text.
4. Click/type/navigate enough to reach a state worth screenshotting (login
   flows, tab switches). Scriptable, not interactive.

## Shape (suggested, not mandated)

- Headless Chromium + a driver (Playwright is likely the least-friction choice
  in nixpkgs; Puppeteer acceptable). Whatever survives the Nix sandbox and the
  dev-sandbox's constraints (no systemd access; check what's already in the
  dev shell).
- Wire into the dev-sandbox home-manager/dev-shell config in this repo wherever
  the sandbox's package set is defined — make it part of the standard sandbox,
  not a per-project flake.
- A thin convenience wrapper is welcome if raw playwright CLI is clunky:
  `webshot <url> [--width N] [--out file.png]` and
  `webdom <url>` (rendered HTML + console errors to stdout) cover 90% of the
  need. Keep it dumb.
- Internal HTTPS: must work against *.gisi.network (mesh CA/cert trust — check
  how other sandbox tools handle it; do not disable verification globally).

## Boundaries

- No proxy/tunnel infrastructure changes. If a target isn't reachable from the
  sandbox, document it; don't re-architect ingress.
- No CI integration, no visual-regression framework. Just the loop: look,
  screenshot, read, fix.

## Acceptance

1. From a fresh dev-sandbox shell: screenshot qb.gisi.network at 1280px and
   390px widths; both PNGs readable and visually correct.
2. Console errors from a page with a deliberate JS error appear in text output.
3. A scripted interaction (navigate → click → screenshot) works.
4. Documented in this repo (short README section or module comment): what's
   installed, the wrapper usage, known limitations.
5. WORKLOG.md with decisions + anything that fought back.
