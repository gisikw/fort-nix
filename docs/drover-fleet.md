# Drover fleet operations

## Shape and trust boundary

Azula is the single Drover coordinator and also a worker. Ratched and O’Brien
are workers. The control API is `https://drover.gisi.network`; the Fort service
declaration uses **VPN** visibility with no additional SSO because every Fort
worker must reach it and Drover authenticates every API/WebSocket operation with
its own separate bearer capabilities. VPN is the least-public Fort visibility
that satisfies that requirement. The backend listens only on
`127.0.0.1:9840`. Gatus is intentionally disabled because Drover has no
unauthenticated health route; `drover-coordinator-health.service` performs the
authenticated local readiness check instead.

The independent constrained SSH rendezvous listens on Azula port 9841 and is
firewalled to the Fort VPN IPv4 prefix. Reverse listeners remain coordinator
loopback-only (24000–24002). No node HTTP port, node SSH port, Herdr socket,
resident Herdr namespace, or private Unix API is exposed. Each node's inner sshd
listens only on `127.0.0.1:22222`.

Immutable inputs are Drover
`0a430be873d1eb7e0929478ef11ba5518f482642`, its lock-pinned Herdr 0.9.0, and
Familiar `0ba216f41e4f7c1b3f5dc6efcba59281034cd7f7`. The latter supplies its
reviewed patched Pi and Tiamat extension source. Every node receives a
Nix-realized PATH containing Drover, Herdr, Pi, Git, Python, rg, fd, OpenSSH,
bash, core utilities, find/grep/sed/awk, tar/gzip, curl and jq before launch.
There is no runtime Nix evaluation or mutable checkout dependency.

## Units and paths

| Host | Supervisor units/jobs | Enrollment generation |
| --- | --- | --- |
| Azula | `drover-coordinator.service`, `drover-coordinator-health.service`, `drover-coordinator-sshd.service`, `drover-node-sshd.service`, `drover-node.service` | 24000 |
| Ratched | `drover-node-sshd.service`, `drover-node.service` | 24001 |
| O’Brien | `network.gisi.drover.node-sshd`, `network.gisi.drover.node` launchd system daemons | 24002 |

Coordinator registry: `/var/lib/drover-coordinator/registry/registry.sqlite`
(0700 parent, `drover-coordinator`). Node home/state:
`/var/lib/drover-node`, `/var/lib/drover-node/state/identity.json`. The stable
node identity is the host name (`azula`, `ratched`, or `obrien`); the identity
file preserves the coordinator-issued token and never-reused port across
restarts.

Each worker owns only the named Herdr namespace `drover`, at
`/var/lib/drover-node/.config/herdr/sessions/drover/herdr.sock`. Its dedicated Pi
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

1. **Azula**. Confirm `drover-coordinator-health.service` succeeds and Azula is
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

## Health and diagnosis

* Coordinator readiness: `systemctl status drover-coordinator-health` on Azula.
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
All daemons restart on failure/keepalive without touching resident Familiar,
Presence, golemd, or user Pi settings.

## Rollback

Roll back all three host generations in reverse deployment order (O’Brien,
Ratched, Azula). A configuration rollback removes supervision and exposure but
does not delete the coordinator registry, node identity, Herdr namespace, Pi
state, or encrypted credentials. Preserve those paths so reapplying the
candidate reclaims the same generation. If retiring the fleet permanently,
revoke nodes first, terminate existing tunnel/jump connections, archive the
registry and node identities securely, and only then remove state in a separate
operator-approved action.
