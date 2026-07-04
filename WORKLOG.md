# WORKLOG: Agent web feedback loop (webshot / webdom)

Dispatch: `instructions-web-feedback-tooling.md` · Ticket: fn-2e1f · Date: 2026-07-04

## What was built

- `pkgs/webtools/` — a `symlinkJoin` of two `writeShellScriptBin` wrappers
  (`webshot`, `webdom`) around a single Python Playwright driver script
  (`webtool.py`). Added to the dev-sandbox `devTools` list in
  `aspects/dev-sandbox/default.nix`, so it's on PATH in every sandbox shell.
- Usage documented in `AGENTS.md` ("Web Feedback Loop" under Dev Sandbox
  Constraints) and in the module comment in `pkgs/webtools/default.nix`.

## Decisions

- **Playwright (Python) + `playwright-driver.browsers`** from nixpkgs 25.11
  (both at 1.56). The nixpkgs Python package is pre-patched to find the
  Nix-store driver; the wrapper pins `PLAYWRIGHT_BROWSERS_PATH` to the
  `playwright-driver.browsers` derivation (Chromium only —
  `withFirefox = false; withWebkit = false` to keep the closure down), so
  there is no `playwright install` step and nothing writes to `~/.cache`.
- **Python over Node** for the driver script: no `node_modules`, no build
  step, and the sync API makes a 130-line script trivial to maintain.
- **Scripting via repeatable `--do 'action:arg'` flags** instead of a script
  file format: `click:`, `fill:`, `press:`, `goto:`, `wait:`, `waitfor:`.
  Dumb, composable from a shell one-liner, covers the navigate→click→shoot
  loop. Anything fancier should just be a real Playwright script (the Python
  env is inside the wrapper, not exposed globally, to avoid colliding with a
  future system `python3`).
- **Console/page-error/failed-request capture** is always on in `webdom`;
  `--a11y` swaps rendered HTML for an ARIA snapshot (`aria_snapshot()`, the
  non-deprecated API); `--quiet-html` gives errors only.
- **Default 1000ms settle wait** after `load` — SPAs (Questbook) render after
  the load event; `networkidle` was rejected because long-polling/SSE apps
  never reach it.

## Things that fought back (or didn't)

- **Internal HTTPS was a non-issue.** The dispatch flagged mesh CA trust, but
  `*.gisi.network` serves public Let's Encrypt certs (ACME DNS-01 via the
  certificate-broker aspect), which Chromium's bundled root store already
  trusts. `ssl_verify_result=0`, no CA wiring, verification stays on.
- **Chromium sandbox worked out of the box** — NixOS ships unprivileged user
  namespaces enabled, so no `--no-sandbox` fallback was needed despite the
  dev-sandbox's limited privileges.
- **Fonts rendered correctly with no extra `fonts.packages`** — verified
  visually on qb.gisi.network screenshots at 1280px and 390px.
- **`PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true` is required** (the
  driver's host-check doesn't understand NixOS). It prints a notice to
  stderr on every run; stdout stays clean, so it was left alone.
- **ko has no `create` subcommand** despite AGENTS.md saying it does — it's
  `ko add`. (AGENTS.md issue-tracking section is stale on this point.)

## Known limitations

- Chromium only (no Firefox/WebKit).
- Each invocation is a fresh browser context — no cookies/session persist
  between runs, so authenticated flows must complete inside one `--do` chain.
- OIDC-gated pages will screenshot the login screen; use VPN-visible or
  `vpnBypass` endpoints, local dev servers, or script the login.
