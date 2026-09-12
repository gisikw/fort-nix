# Drover fleet operations

## Shape and trust boundary

Azula is the single Drover coordinator and also a worker. Ratched and O’Brien
are workers. The control API is `https://drover.gisi.network`; the Fort service
declaration uses **VPN** visibility with no additional SSO because every Fort
worker must reach it and Drover authenticates every API/WebSocket operation with
its own separate bearer capabilities. VPN is the least-public Fort visibility
that satisfies that requirement. The backend listens only on
`127.0.0.1:9840`. Gatus is intentionally disabled because Drover has no
unauthenticated health route. Every `drover-coordinator.service` start runs an
authenticated local `/v1/machines` check as `ExecStartPost`; the service does not
become active until that check succeeds.

The independent constrained SSH rendezvous listens on Azula port 9841 and is
firewalled to the Fort VPN IPv4 prefix. Reverse listeners remain coordinator
loopback-only (24000–24002). No node HTTP port, node SSH port, Herdr socket,
resident Herdr namespace, or private Unix API is exposed. Each node's inner sshd
listens only on `127.0.0.1:22222`.

Immutable inputs are Drover
`0a430be873d1eb7e0929478ef11ba5518f482642`, its lock-pinned Herdr 0.9.0, and
Familiar `0ba216f41e4f7c1b3f5dc6efcba59281034cd7f7`. The latter supplies its
reviewed patched Pi and Tiamat extension source. Every node receives one
Nix-realized runtime containing Drover, Herdr, Pi, Git, Python, rg, fd, OpenSSH,
bash, core utilities, find/grep/sed/awk, tar/gzip, curl
and jq. Herdr's node-owned `terminal.default_shell` sources that immutable
Drover environment after system interactive-shell startup, so every agent pane
receives the same canonical runtime even when `/etc/profile` re-derives `PATH`.
This is node provisioning, not a Familiar per-job environment or a project
`nix develop`; there is no runtime Nix evaluation or mutable checkout
dependency.

## Units and paths

| Host | Supervisor units/jobs | Enrollment generation |
| --- | --- | --- |
| Azula | `drover-coordinator.service` (including its readiness post-start), `drover-coordinator-sshd.service`, `drover-node-sshd.service`, `drover-node.service` | 24000 |
| Ratched | `drover-node-sshd.service`, `drover-node.service` | 24001 |
| O’Brien | `network.gisi.drover.node-sshd`, `network.gisi.drover.node`, `network.gisi.drover.node-terminal-cleanup` launchd system daemons | 24002 |

Coordinator registry: `/var/lib/drover-coordinator/registry/registry.sqlite`
(0700 parent, `drover-coordinator`). Node home/state:
`/var/lib/drover-node`, `/var/lib/drover-node/state/identity.json`. The stable
node identity is the host name (`azula`, `ratched`, or `obrien`); the identity
file preserves the coordinator-issued token and never-reused port across
restarts.

Each worker owns only the named Herdr namespace `drover`, at
`/var/lib/drover-node/.config/herdr/sessions/drover/herdr.sock`. The declarative
`/var/lib/drover-node/.config/herdr/config.toml` selects a dedicated immutable
shell wrapper; its rcfile sources system shell defaults and then the node-owned
Drover environment, making the reviewed Pi executable authoritative in every
new pane. It does not source mutable project or user rcfiles. The dedicated Pi
profile is `/var/lib/drover-node/pi`; `settings.json` is a declarative store
symlink that enables only Familiar's reviewed Tiamat extension and sets
`defaultProjectTrust` to `never`. Its environment names
`https://router.gisi.network` and the host-local, mode-0400 router token file.
It neither reads a user's Pi profile nor enables the Agents extension globally.
Familiar Agents' `familiar-tiamat-v1` path therefore remains authoritative: it
creates a per-job profile from exactly its four allowlisted source assets,
digest-pins that bundle, installs Herdr's Pi integration, and applies its
per-job exact-model guard.

O’Brien logs are `/var/log/drover-node.log` and
`/var/log/drover-node-sshd.log`. Linux logs are in journald. All Drover bearer
capabilities and private SSH keys are separate sops-nix files under
`aspects/drover/secrets/`, materialized 0400 or narrowly shared 0440. The shared
Tiamat ciphertext already used by each host is reused; no token is copied into
the store. Azula also materializes the Familiar Agents client key at
`/run/secrets/drover-agents-client-key`. Existing O’Brien admin/CI SSH
authorization is untouched; managed node transport is additive, not the only
road home.

## Deployment and first enrollment

Enrollment ports are generation fences and never reused. On an empty registry,
deploy in this exact order:

1. **Azula**. Confirm `drover-coordinator.service` is active (which means its
   current authenticated post-start readiness check succeeded) and Azula is
   enrolled as port 24000.
2. **Ratched**. Confirm it appears online as port 24001.
3. **O’Brien**. Confirm it appears online as port 24002.

Do not activate the three fresh nodes concurrently. Static SSH
`permitlisten`/`permitopen` policy intentionally fails closed if the registry's
allocation differs. In that case stop before dispatching work: inspect catalog
metadata without logging credentials, revoke only the incorrect fresh
registrations, remove only their corresponding persisted node identity files,
and repeat serial enrollment. Never replace an established registry merely to
recover expected numbering.

Before enabling a Familiar controller, build its private Agents configuration
from the authenticated catalog tuples. Pin each name/session/host key/SSH
user/**actual port**, use `profile_mode: "familiar-tiamat-v1"`, the Nix store
Herdr/Python paths from the deployed generation, an explicit worker PATH, and
remote `FAMILIAR_TIAMAT_TOKEN_FILE` from that host generation. Do not guess
ports or copy an ambient controller profile.

## Supervisor, readiness, and diagnosis

The pinned Drover `serve` implementation has two internal infinite retry loops.
The SSH reverse-tunnel loop retries every SSH exit with exponential delay capped
at 30 seconds. After an identity exists, the control WebSocket loop retries DNS,
TCP, TLS, timeout, clean-disconnect, and other non-auth connection failures with
the same capped delay. A control handshake status 401 or 403 is deliberately
raised as `RuntimeError("machine revoked or credential invalid; re-enroll
explicitly")`. Initial enrollment transport or non-auth failures occur before
the control retry loop and therefore exit for supervisor retry; initial
registration 401/403 is also a terminal credential failure. Herdr bootstrap,
namespace/config validation, malformed persisted identity, and unexpected
Python failures exit abnormally and are supervisor-restarted.

The fort-nix adapter calls that exact pinned `serve` coroutine. It maps only the
pinned 401/403 failure chain to a clean terminal exit; it does not alter
Drover's retry loop or manufacture a distinction among unrelated errors.
Unexpected exceptions and signal/crash deaths remain failures. Accordingly,
Linux uses `Restart=on-failure`, while launchd uses the documented dictionary
form `KeepAlive = { SuccessfulExit = false; }`: in launchd, that condition keeps
a job alive after unsuccessful/non-zero or signalled exits, not after status 0.
A supervisor-requested SIGTERM is a clean stop.

A terminal node exit creates `/var/lib/drover-node/state/terminal-auth` and
removes `sshd-enabled`. On Linux, `ExecStopPost` then stops
`drover-node-sshd.service`. On O’Brien, `sshd-enabled` is the sshd job's
`KeepAlive.PathState`; the root terminal-cleanup watch job terminates the
already-running sshd after the marker appears. Linux also conditions sshd
startup on that marker being absent, and Darwin launches sshd only while the
enabled path exists. Thus the loopback endpoint does not remain misleadingly
available after revocation, including across reboot. Neither platform restarts
the cleanly exited node, and an automatic boot start remains gated. Once an
operator has authorized re-enrollment, install the corrected credential and
remove the revoked persisted identity according to the serial procedure, then
remove `terminal-auth` and start `drover-node.service` or kickstart
`system/network.gisi.drover.node`. That start performs enrollment and recreates
the enabled marker and sshd. Do not remove the marker or repeatedly start the
node with the old identity.

Coordinator readiness is not a remembered oneshot. A failed authenticated
`ExecStartPost` fails the coordinator activation and `Restart=on-failure`
retries the complete start. Azula's node is `BindsTo` and `PartOf` the
coordinator and ordered after it, so a later coordinator stop/failure stops the
node. Only after the restarted coordinator passes its new readiness check does
the root post-start enqueue the local node again.

* Coordinator readiness: `systemctl status drover-coordinator` on Azula and
  inspect the current invocation's post-start result.
* Fleet/authenticated lease view: GET `/v1/machines` through
  `https://drover.gisi.network` using the client token file (never place the
  token in command history or argv).
* Node: check its supervisor unit/job, then use authenticated catalog `online`
  state. `online` proves the control WebSocket, not the SSH tunnel.
* Namespace: as `drover-node`, run the pinned Herdr's socket `ping` against the
  named `drover` session. Do not start the resident/default Herdr session.
* SSH: verify the node loopback sshd, Azula rendezvous sshd, and reverse listener
  separately. Never use keyscan or disable strict host checking.

A revoked/invalid node credential requires explicit revocation and enrollment;
do not blindly retry mutations. RPC timeout/disconnect means outcome unknown.
The coordinator and systemd nodes have bounded stops; launchd uses `ExitTimeOut`.
Abnormal failures restart without touching resident Familiar, Presence, golemd,
or user Pi settings; terminal credential exits follow the stopped behavior
above.

Secret contents are read only at process start. After deliberately rotating a
node enrollment token, node identity, tunnel key, host key, Tiamat token, or
coordinator enrollment/client token, restart the exact consuming node, node
sshd, or coordinator/sshd job as part of that rotation and repeat the
authenticated readiness/catalog/SSH checks. On Azula, restart the coordinator
first; its readiness coupling re-gates the local node. On O’Brien, use an
explicit launchd kickstart after installing the new generation. A ciphertext
change alone does not update an already-running process. Preserve serial
re-enrollment and never delete an established identity merely to force token
pickup.

## Rollback

Roll back all three host generations in reverse deployment order (O’Brien,
Ratched, Azula). A configuration rollback removes supervision and exposure but
does not delete the coordinator registry, node identity, Herdr namespace, Pi
state, or encrypted credentials. Preserve those paths so reapplying the
candidate reclaims the same generation. If retiring the fleet permanently,
revoke nodes first, terminate existing tunnel/jump connections, archive the
registry and node identities securely, and only then remove state in a separate
operator-approved action.
