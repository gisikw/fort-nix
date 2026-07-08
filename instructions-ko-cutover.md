# Dispatch: Knockout → Questbook cutover

**Context:** Questbook (qb.gisi.network, `~/Projects/questbook`) is replacing
Knockout as the primary ticketing system. Both sides are built: questbook has a
bulk-import endpoint (commit `4381e22`, see `docs/ko-import.md` + WORKLOG.md);
knockout has `ko export` + an opt-in QQL compat shim + read-only legacy mode
(see `EXPORT_SCHEMA.md`, `QQL_MAPPING.md`, WORKLOG.md in `~/Projects/knockout`).
Design authority: `~/briefs/questbook.md` §10 Slice 1. This dispatch performs
the actual cutover: import, flip, smoke.

**The one untested seam (highest-risk step, do it first):** the two sides were
built by different agents against a contract neither saw the other implement.
Questbook's import was built from a direct ko DB snapshot BEFORE `ko export`
existed. Reconcile before anything else.

## Order of operations (strict — the ordering is load-bearing)

### 1. Contract reconciliation
- Compare knockout `EXPORT_SCHEMA.md` against questbook `docs/ko-import.md` and
  the actual import code. Run `ko export`, dry-run it against the import
  endpoint. Fix whichever side is cheaper to fix (schema doc says the JSON file
  is the contract; prefer adapting the importer over changing export shape).
  If the mismatch is structural and ambiguous, STOP and park a question.

### 2. Field/mapping rulings (already made — apply, don't re-litigate)
- **Snooze: dropped.** Kevin's explicit ruling — tickler/cron behavior becomes
  Kobold's job. Do not migrate.
- **Assignee/tags/triage: dropped by default.** Not in the preserve list. Note
  counts in the worklog; legacy data stays readable in read-only ko, so this is
  reversible later.
- **Realm mapping:** use the mapping the Slice 1 agent produced (exo→exocortex,
  lr→lair, mus→muse, tmt→tiamat, unk→unkork, strays→inbox, rep kept). Apply
  as-is; list the final mapping prominently in the worklog for Kevin's morning
  review. Only deviate if something is factually broken (e.g. target realm
  collides with an existing different-purpose realm).

### 3. Import (nothing user-facing changes yet)
- `ko export` → full dump. Dry-run → verify counts against export (27 projects
  / 1405 tickets at last check, minus documented skip rules).
- Real import. **Re-run once to prove idempotency** (counts must not change).
- Spot-check via QQL and qb.gisi.network: several known tickets, deps intact,
  ko IDs present as external refs.

### 4. Backup insurance (before the flip, not after)
- Close out quest `q-3f9716b1`: verify `/var/lib/questbook/` (questbook.sqlite)
  is covered by ratched's restic backup config in this repo. If it isn't, add
  it in this commit. Questbook is about to hold 1400 tickets; this is now
  mandatory, not hygiene.

### 5. The flip (fort-nix edits, this repo)
- **Ship the realm-mapping YAML as a fort-nix-managed file** readable in both
  contexts below.
- **Dev sandbox** (`aspects/dev-sandbox/default.nix`): set `KO_QQL=1`,
  `KO_QQL_URL` (qb.gisi.network or mesh-internal), `KO_QQL_MAPPING=<managed
  path>`, `KO_READONLY=1`.
- **Ratched knockout overlay** (`clusters/bedlam/hosts/ratched/manifest.nix`):
  same vars, plus explicit `KO_SHIM_LOG` path (e.g. under the overlay's data
  dir) so the serve-side usage log is findable — this log is the cutover's
  vital sign; the remote/HTTP path (Punchlist et al) flows through here.
- Commit, push, let GitOps deploy, then **restart the knockout overlay**
  (`fort ratched systemd restart <overlay unit>`) — env loads at startup; a
  deploy without restart silently changes nothing (known gotcha class).

### 6. Smoke (prove the flip)
- Fresh sandbox shell: `ko add "cutover smoke" --project=inbox` → quest
  appears in Questbook; JSONL usage log recorded the invocation.
- A legacy-store write path rejects with the QQL pointer (exit 3).
- `ko ls` output through the shim is sane for a couple of projects.
- Remote path: one shim-routed operation through ko.gisi.network if
  reachable from the sandbox; otherwise verify via journal that serve came up
  with the new env.

## Boundaries
- Do NOT modify questbook's or knockout's Go code beyond what step 1 requires
  (importer-side adaptation only; commit in the owning repo with a clear
  message).
- Do NOT delete or compact any ko data. Legacy store stays intact, read-only.
- The "watch the usage log drain" phase is NOT yours — it's a multi-day
  passive observation. Note the log locations in the worklog and stop.

## Acceptance
1. Import: full ticket corpus in Questbook, idempotent, ko external refs
   preserved, spot-checks pass.
2. restic covers questbook.sqlite (q-3f9716b1 closeable).
3. Both contexts flipped; smoke checklist above passes end-to-end.
4. WORKLOG entry (this repo): final realm mapping table, dropped-field counts,
   log file locations, any importer-side commits made, anything that fought
   back.
