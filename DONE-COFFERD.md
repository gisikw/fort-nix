# DONE — lordhenry cofferd convergence

**Goal (met):** cofferd running on lordhenry, enrolled with coffer-server
(drhorrible), lordhenry showing **PENDING** to the coffer-server. Kevin's
manual steps (approve machine, then place the tiamat grant) remain — see
"Remaining Kevin steps" below. No coffer-web approvals or grant tokens were
placed by this run.

## Final state (verified 2026-07-19 ~20:2x UTC, all via `fort`)

- `overlay-coffer-cofferd.service` → **active / running** (`load=loaded`).
- cofferd journal, call-home succeeded:
  ```
  20:19:13 cofferd: registered as "lordhenry", state=pending
  20:19:13 cofferd: machine state=pending — waiting for approval
  20:19:13 cofferd: workload "tiamat": waiting for grant /var/lib/cofferd/grants/tiamat.grant
  20:20:13 cofferd: machine state=pending — waiting for approval   (steady poll, same PID, no restart)
  ```
  "registered as lordhenry, state=pending" is the coffer-server (drhorrible)
  acknowledging the enrollment — server-side confirmation that lordhenry is a
  known **pending** machine. (coffer-web itself is loopback-only on drhorrible;
  the cofferd registration ack is the read-only proof reachable from ratched.)
- gitops **converged, no rollback**: switch at 20:16:33 revived the coffer
  user/group, started the mint oneshot, printed **no "units failed" warning**
  and **no rollback** lines, then `fort-gitops-switch.service: Deactivated
  successfully`. `/run/current-system` → the new closure
  (`wk2cy9g6…-nixos-system-lordhenry`) as of 20:16.
- gitops idle-clean: `fort-gitops.timer` active/waiting; `systemd failed` → 0
  units.

## Root-cause chain (all layers)

**Layer 1 — uid pin (fixed pre-run, 47b2e5f).** The `lordhenry-cofferd`
branch pinned tiamat at uid 491. NixOS refuses uid changes on existing users,
so `switch-to-configuration` returned status 4 → rollback. Commit 47b2e5f
re-pinned tiamat at its *real* uid **992**. On main.

**Layer 2 — poison runtime unit + user-removal loop (treated by supervisor).**
A stale `/run/systemd/system/overlay-coffer-cofferd.service` (enabled-runtime,
written by an earlier overlay-manager activation, `User=coffer`) crash-looped
with **217/USER**: each rollback removed the `coffer` user, so the unit could
never resolve its user; its restart counter hit ~142 and tripped systemd's
start limit. Every subsequent switch saw that unit in a failed/activating
state → `switch-to-configuration` status 4 → rollback → coffer user removed
again. Self-sustaining loop. The supervisor **stopped** the unit (~20:15,
confirmed inactive/dead) to break it.

**Layer 3 — the switch simply had not re-run since the unit was stopped
(the actual remaining blocker; suspect #1).** With the poison unit dead
(not crash-looping), the very next gitops switch — **20:16:33** — activated
cleanly:
```
20:16:33 activating the configuration...
20:16:33 reviving group 'coffer' with GID 986
20:16:33 reviving user  'coffer' with UID 990
20:16:34 the following new units were started: cofferd-mint-client-cert.service
20:16:54 fort-gitops-switch.service: Deactivated successfully   (no rollback)
```
The difference from the failing 19:44 switch: at 19:44 the poison unit was
still auto-restarting and reported failed → status 4; at 20:16 it was
supervisor-stopped/dead, so activation saw no failed unit. The new generation's
overlay manager (which now carries the `coffer` subscription — the rolled-back
old generation did not) then picked up coffer at **20:19:13**, fetched the
store path, stopped the stale unit, and started cofferd fresh against the
now-existing coffer user → registration → pending.

## Suspects from the brief — dispositions

1. **Switch hadn't run since the unit was stopped** — ✅ this was it. Converged
   on the first switch after the stop (20:16). The recurring
   `fort-gitops-cache` "Bad NAR Hash or Size" error (on `…-system-units`) and a
   whisper `ggml-large-v3.bin` HTTP 413 are **non-fatal** — those paths were
   deduplicated / fetched by other substituters; the closure completed and the
   switch activated.
2. **Stale runtime unit resurrects** — no. The new-gen overlay manager owns the
   unit now and started it healthy against the real user.
3. **Cert/ownership residue (990:986)** — cleared. `/var/lib/cofferd/client.crt`
   and `client.key` are owned `coffer:coffer`, and the recreated coffer user is
   **uid 990 / gid 986** — identical to the "old" ids, so there is no mismatch.
   tmpfiles (`d /var/lib/cofferd 0750 coffer coffer`) + the mint oneshot's
   `chown coffer:coffer` (by name) keep it correct regardless.
4. **Trust anchor** — cleared. `clusters/bedlam/coffer-server.crt` SHA-256
   fingerprint `12:BA:6E:BD:AD:BF:58:84:A2:B6:06:A4:B3:50:09:95:22:34:01:AF:AD:C8:B6:0A:23:D3:6C:C6:35:1B:20:A4`
   == ratched's trusted `/etc/cofferd/server.crt` == lordhenry's
   `/etc/cofferd/server.crt`. cofferd's successful TLS registration confirms the
   anchor works end-to-end.
5. **Enrollment path** — cleared. cofferd reached
   `https://drhorrible.fort.gisi.network:7787` and registered; no TLS/connection
   errors in the journal.

## One nuance — pre-approval health-check flap (not a blocker)

The overlay manager's health probe for coffer is `type=exec`,
`cofferd --healthcheck`. Pre-approval it returns non-zero (cofferd is
legitimately *running-but-pending*), so the manager logs
`[coffer] health checks failed, rolling back` → `no previous version to
rollback to` and leaves cofferd running — but it never records a *successful*
activation. Consequence, observed across cycles (20:19:13, 20:24:36, …): every
~5-minute manager tick treats coffer as "new version available", **stops and
restarts** `overlay-coffer-cofferd.service`, and fails health again. So
**cofferd flaps (restarts every ~5 min) until the machine is approved.**

This does **not** block the goal or any Kevin step:
- Each restart re-runs the identical registration (idempotent) and lordhenry
  stays **pending** to the server — PENDING visibility persists across flaps.
- No consumer depends on the socket yet (the tiamat grant is not delivered), so
  the brief restarts have no downstream impact.
- Approving the machine makes `cofferd --healthcheck` pass, the manager records
  a healthy activation, and the flap stops — cofferd stabilizes and serves.

Tracked as **ko q-5b2fc4fd** for a proper fix (coffer overlay.nix health semantics:
`cofferd --healthcheck` should report *ready* while pending, or the daemon
overlay should use a liveness probe rather than a readiness one). This lives in
the **coffer project repo's `overlay.nix`**, not fort-nix — no fort-nix change
is warranted here.

## Remaining Kevin steps (manual, by design — not done by this run)

1. In **coffer-web** on drhorrible, **approve the `lordhenry` machine**
   (pending → approved).
2. Then **place / approve the `tiamat` workload grant** (`fort/openai/cred`).
   cofferd is waiting for `/var/lib/cofferd/grants/tiamat.grant`.
3. Once approved + grant delivered, cofferd serves `fort/openai/cred` over
   `/run/cofferd/coffer.sock` (0660 coffer:coffer; tiamat is in the coffer
   group), and tiamat's Sol/GPT arms resume on coffer-served OAuth.
