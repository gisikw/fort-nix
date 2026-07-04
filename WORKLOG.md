# WORKLOG: Knockout → Questbook cutover

Dispatch: `instructions-ko-cutover.md` · Date: 2026-07-04

The ko → qb cutover: imported the full ko corpus into Questbook, flipped `ko`
(dev shell + serve overlay) onto the QQL compat shim with the legacy store
frozen read-only, and put restic insurance under `questbook.sqlite`. Done and
verified end-to-end.

## Outcome vs acceptance

1. **Import** — 1405 tickets / 27 ko projects → Questbook. Idempotent (re-run:
   0 created, 1405 `skipped_existing`). 356 deps, 0 dangling deps/parents, 22
   realms. ko IDs preserved as `external_ref = "ko:<id>"`. Spot-checks pass
   (titles, status mapping closed→done, deps resolve to `q-` ids, realm counts
   match export). Live total: 1452 quests (1405 imported + 47 pre-existing).
2. **Backup** — restic `restic-backups-questbook.{service,timer}` (daily) takes
   a consistent `sqlite3 .backup` snapshot before pushing (a raw copy of a live
   SQLite file can be torn). Ran once: snapshot `0e312286` saved, 1.547 MiB.
   Quest `q-3f9716b1` closed.
3. **Flip** — both contexts on ratched, verified live:
   - Dev shell (gated to hosts with a local qb overlay): `KO_QQL=1`,
     `KO_QQL_URL=http://127.0.0.1:19877`, `KO_QQL_MAPPING=/etc/knockout/qql-mapping.yaml`,
     `KO_READONLY=1`.
   - Knockout overlay (serve side): same, plus
     `KO_SHIM_LOG=/var/lib/knockout/shim-usage.jsonl`.
4. **Smoke** — all pass: `ko add "cutover smoke" --project=inbox` → `q-c4712dd2`
   in qb + dev usage log; legacy write (shim off, `KO_READONLY=1`) → exit 3 with
   QQL pointer; `ko ls` sane for several projects; **public remote path**
   `ko.gisi.network/ko` routes serve→shim→qb (200, live data); journal shows
   `ko serve: listening on :19876` with the new env.

## Final realm mapping (for review)

Canonical map lives in two synced files: questbook `internal/questbook/ko-mapping.json`
(bulk import) and `aspects/dev-sandbox/qql-mapping.yaml` (shim; installed at
`/etc/knockout/qql-mapping.yaml`). Applied the Slice-1 rulings as-is and
**extended for tags that had drifted since that snapshot** (importer hard-fails
on unmapped tags that carry tickets):

| ko tag | realm | note |
|--------|-------|------|
| fort-nix, cranium, cupola, discovery-zone, gee, headjack, hearth, knockout, kobold, litmus, maw, punchlist, research, tickler | *(same)* | direct tag=realm |
| exo, exo-tiamat-gpt, **interview** (98) | exocortex | `interview` is a misnamed tag — all 98 tickets use the `exo-` prefix and are exocortex bridge/@exo/capture work. **Judgment call — flag for review**; reversible via `qb mutate`. |
| tmt (43), **tmx** (18) | tiamat / tokenmaxx | drifted prefixes (tmt→tiamat merges with 13 pre-existing native Tiamat quests — same-purpose, not a collision) |
| **lair** (7), lr | lair | export uses `lair`; mapping only had `lr` |
| **grt** (1) | grotto | grotto soak ticket |
| mus | muse | |
| unk | unkork | |
| 001, 002, project, user, giz | inbox | strays / triage |
| gloss, hoard, phy, qb | *(self / phylactery / questbook)* | 0 tickets at cutover; added for future-proofing |

Bold = added/changed this cutover. `default_realm: inbox` in the shim YAML.

## Dropped fields

Per the rulings: assignee / tags / snooze / triage are **not migrated** (not in
the preserve list; still readable in read-only legacy ko, so reversible).
Import counted `fields_dropped: 166` (tickets carrying ≥1 dropped field) and
`untitled: 2` (empty titles → `(untitled ko import)` placeholder). **Snooze**
dropped entirely per Kevin's ruling (tickler/cron becomes Kobold's job).

## Log file locations (the cutover's vital sign — watch these drain)

- **Serve side** (Punchlist et al. via `ko.gisi.network`): `/var/lib/knockout/shim-usage.jsonl` on ratched.
- **Dev shell** (interactive/agent `ko`): `~/.local/state/knockout/shim-usage.jsonl` (KO_SHIM_LOG unset in the shell → shim default).

The "watch the log drain" phase is a multi-day passive observation — NOT part of
this dispatch (per boundary). Note the locations and stop.

## Commits made (owning repos)

- **questbook** `d187bfd` — importer natively accepts the `ko export` envelope
  (nested `projects[]`, `id`→`ticket_id`, `created/modified`→`created_at/updated_at`);
  trued up embedded `ko-mapping.json`. Only these 3 files (repo had unrelated
  Slice-2 WIP in the tree — left untouched).
- **knockout** `b43ae68` — committed the pre-existing but uncommitted qql-shim
  dispatch (export + shim + readonly). `e0a3ec2` — `overlay.nix` threads the
  KO_ env from host config. `84cb00a` — shim drops the `return` key from mutate
  calls (qb's hardened mutate rejects it → `ko add` was failing). `faa809d` —
  exempt `serve` from shim interception (KO_QQL made `ko serve` crash-loop).
- **fort-nix** `1143edd` — the flip (this repo): mapping YAML, dev-shell env
  (gated on `hasLocalQb`), overlay config, `/var/lib/knockout` tmpfiles, restic.

## What fought back (four untested seams, all cross-agent contract drift)

1. **Export ↔ import shape.** ko export is nested-by-project with `id`/`created`/
   `modified`; the importer wanted a flat `tickets[]` with `ticket_id`/`created_at`.
   Adapted the importer (the schema doc is the contract; import built from a pre-
   export DB snapshot). Also: `ko export` didn't exist on the deployed overlay —
   the whole qql-shim work was uncommitted.
2. **Mapping drift.** ko tags renamed/added since the snapshot the map was built
   from — `interview`/`tmx`/`lair`/`grt` carried tickets but were unmapped
   (importer hard-fails). Extended the map (above).
3. **Shim `return` key.** qb's Slice-1 mutate rejects unknown keys; the shim sent
   `return` → `ko add` broke. qb returns `id_map` natively, so dropped it.
4. **`ko serve` under KO_QQL.** The shim intercepted `serve` itself → overlay
   crash-loop. But serve execs a fresh `ko` per remote request (inheriting
   KO_QQL), so exempting only `serve` makes the daemon boot while every remote op
   still routes to qb + logs. This is what makes the serve-side flip real.

Process note: I smoke-tested the shim against **live** qb rather than a scratch
DB, which created junk (below). Should have used a scratch qb like I did for the
importer.

## ⚠️ Cleanup owed (qb has NO delete API; DB is DynamicUser-owned → couldn't remove)

Empty realms (from `ko ls` run with a bad flow-style mapping, since fixed, + one probe):
`r-574a6cf1` cutover-probe-realm, `r-f54ce672` `{ realm: cranium }`,
`r-94138225` `{ realm: fort-nix }`, `r-56df6453` `{ realm: knockout }`,
`r-ec812e45` `{ realm: research }`, `r-723c8220` `{ realm: tiamat }`.
Test quests (inbox): `q-dda82fb4`, `q-f00407d3`, `q-652e32df`, `q-3c9093b4`
(all "… DELETE ME"), and `q-c4712dd2` "cutover smoke". **These need a Questbook
delete capability (or manual DB deletion) to remove** — worth a qb ticket.

## Not flipped: raishan

raishan also has the `dev-sandbox` aspect but no local qb overlay, so the shell
flip is gated off there (`hasLocalQb`) — its `ko` stays native rather than
pointing at a qb that isn't there. Deliberate; revisit if raishan needs qb.

---

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
