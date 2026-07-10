# DONE — Darwin parity audit + parameterization

Branch: `burn/darwin-parity` (7 code/doc commits + this file). Full inventory
and rationale live in `docs/darwin-parity-audit.md`; this file is the
execution summary.

## What was done

1. **Audited** `common/`, `aspects/`, `roles/`, `core/`, `device-profiles/`,
   `clusters/bedlam/`, `pkgs/fort*`, `apps/fort-*`, gitops, and CI for
   Linux-specific assumptions (four parallel deep-read passes + repo-wide
   greps). Big picture: the platform dispatch, control-plane launchd
   services, mesh, and gitops-lite were already in place on main; the seed
   quests q-6b76fb89 / q-54520608 / q-4c48ba93 are substantially done there.
   The real gaps were the two open bugs (journal, launchd throttle), missing
   status/deploy state on darwin, and ungated Linux-only aspects.
2. **Fixed** the darwin journal handler (q-314c1d31), the launchd restart
   throttle + label resolution (q-d9b7ef7b), gave darwin gitops
   deployed-commit tracking + exponential failure backoff, ported
   host-status to darwin (launchd status.json writer, now a default aspect
   on both platforms — `fort obrien status` gets real uptime/failed-units/
   deploy data), added explicit fail-fast platform gates to 14 Linux-only
   aspects, and made CI force-evaluate `darwinConfigurations`.
3. **Documented** everything else: what's correctly gated by architecture,
   what was deliberately left alone (and the two `src = ./.` traps that make
   "free" edits impossible in emergency-reboot and fort-overlay-manager),
   and what needs hardware or a decision (§3–4 of the audit doc).

## Commits (low → med; docs last, doc-only)

| Commit | Tier | Subject |
|--------|------|---------|
| 0cc68a2 | low | control-plane: fix darwin journal + systemd handlers, provider throttle |
| 3a7136a | low | gitops: darwin deployed-commit tracking + failure backoff |
| ab0e24d | low | host-status: darwin branch (launchd status.json writer) |
| c69182c | low | ci: force-evaluate darwinConfigurations in release checks |
| 0607ab1 | med | host.nix: host-status is a default aspect on darwin too |
| fd6bca2 | med | aspects: explicit Linux-only platform gates (14 aspects) |
| e7675ed | low | docs: darwin parity audit |

No high-tier commits: nothing on this branch changes what a Linux host
evaluates to (proven below), and the genuinely high-risk ideas (darwin
rollback, gitops mechanism merge beyond state-model convergence, upload on
darwin) were deliberately documented instead of attempted — they need
hardware or a decision (audit doc §4).

Cherry-pick notes: 0607ab1 (`[med]` host.nix) requires ab0e24d (`[low]`
host-status) or darwin eval breaks. Everything else is independent.

## Verification actually run (Linux dev sandbox; no Darwin hardware, no
deploys, no live-host mutations)

- `git diff main -- flake.lock '**/flake.lock'` → **empty** (root and all
  per-host/cluster lockfiles untouched).
- **drv-path comparison, all 13 NixOS hosts** (azula, doofenshmirtz,
  drhorrible, frankenstein, joker, lordhenry, minos, pettigrew, q, raishan,
  ratched, robotnik, ursula): evaluated
  `nixosConfigurations.<host>.config.system.build.toplevel.drvPath` from the
  branch working tree and from a `main` worktree — **all 13 IDENTICAL**
  (e.g. ratched `p7n5pb0rgh6ajmm3c9xjplrfhapk143r-nixos-system-ratched-…drv`
  on both). This covers low+medium tiers together and every gated aspect in
  actual use. Two intermediate regressions were caught and reverted this
  way (`meta` addition to fort-overlay-manager and the emergency-reboot
  gate, both `src = ./.` self-hash traps).
- `nix eval ./clusters/bedlam/hosts/obrien#darwinConfigurations.obrien.config.system.build.toplevel.drvPath`
  → evaluates cleanly (`7hy9w4vbkb5qp67wbi4zg3k9qb1w1r38-darwin-system-…drv`;
  differs from main as intended — new status daemon, updated handlers).
- `nix flake check --no-build` on the root flake, ratched's host flake, and
  obrien's host flake → all pass. (Noted: flake check does not deep-eval
  darwinConfigurations on Linux — hence the new CI step.)
- `go build ./...` + `go vet` + `go test ./...` in `pkgs/fort-provider`,
  `pkgs/fort-upload`, `pkgs/fort-tokens`, `pkgs/fort-overlay-manager` →
  build/vet clean; **no test files exist in any fort package** (pre-existing;
  `go test` reports "no test files").
- Aspect gate behavior: direct `nix-instantiate --eval` of gated aspects
  with `platform = "darwin"` → throws
  `fort-nix: aspect 'zfs' is Linux-only (…); remove it from this darwin
  host's manifest`; with `platform = "nixos"` → returns the module attrset.

## Needs Darwin hardware to verify (in suggested order, on obrien after cherry-pick)

1. `fort obrien status` — expect `status: "running"`, real uptime,
   `deploy.commit` populated after the first post-deploy gitops tick.
2. `fort obrien journal '{"unit":"fort-provider"}'` — expect log lines from
   `/var/log/fort-provider.log` (this was the empty-results bug).
3. `fort obrien systemd '{"action":"restart","unit":"fort-provider"}'`
   twice in quick succession — both should succeed (second used to hit the
   launchd throttle); response reports `"method": "bootstrap"`.
4. `fort obrien systemd '{"action":"list"}'` / `'{"action":"status","unit":"fort-gitops"}'`
   — label resolution for short names.
5. Push a commit, watch `/var/log/fort-gitops.log` — expect
   deployed-commit written on success; push a deliberately broken commit —
   expect backoff messages instead of a 30s retry storm.
6. Root-cause of q-d9b7ef7b (why the provider crashes at early boot) —
   `ThrottleInterval`/bootstrap fix the symptom; the boot-time log will show
   the cause.

Not attempted (documented in audit §4): darwin rollback on failed switch,
manualDeploy/deploy capability on darwin, test-branch gitops (absent on both
platforms in this repo), file upload to darwin hosts, attic push of darwin
closures.
