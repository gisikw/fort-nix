# Azula familiar-ui activation contract

`familiar-ui.gisi.network` is a production static build plus two same-origin
proxy routes into the **existing** `familiar-instance-presence` Pi. It never
starts Pi, uses Pi RPC, or embeds the Pi SDK.

## Trust boundaries

- nginx serves only the tracked profile's immutable `web/` output. It receives
  no bind mount into `/home` or `/var/lib/kestrel`.
- The in-process extension binds `127.0.0.1:8795`. nginx rewrites the upstream
  `Host` to exactly `127.0.0.1:8795`; the bridge independently requires the
  exact `Origin: https://familiar-ui.gisi.network` and the per-session bearer.
- `/__familiar/bridge.json` is identity-authenticated and proxied over
  `/run/familiar-ui/broker.sock`. The broker runs with UID `familiar`, validates
  the 0600 regular descriptor in tmpfs, validates origin/loopback port/version,
  strips process metadata and rewrites only `url` to the public same origin.
  nginx cannot read the descriptor file. The token is `no-store`, never a URL,
  cookie, Nix value, nginx argument, or log field.
- A new Pi session still creates a new epoch and token. Existing action ids,
  session ids and cursors retain familiar-ui's stale/reset semantics; reload a
  stale browser tab to acquire the replacement descriptor.

## Required Familiar change (compile-check before activation)

Familiar's `run_pi` currently replaces `.extensions` with a fixed list on every
Presence birth. Add one bounded environment input in `familiar.sh`:

1. Parse `FAMILIAR_PI_EXTRA_EXTENSIONS_JSON`, defaulting to `[]`, with `jq -ce`.
2. Require an array of at most 16 non-empty absolute strings; fail closed before
   writing `settings.json` on malformed input.
3. Pass it to the settings `jq` as `--argjson extraExts ...` and form
   `extensions: (builtIns + $pluginExts + $extraExts | unique)`.
4. Add a shell test proving malformed/non-array/relative values fail, duplicates
   collapse, and the existing list and plugin list remain.
5. Compile/test this contract against Familiar's pinned Pi 0.84 extension API.

Fort declares the next Presence environment as:

```text
FAMILIAR_PI_EXTRA_EXTENSIONS_JSON=["/etc/familiar-ui-extension/index.js"]
```

The wrapper sets the origin, fixed loopback port and `/run` descriptor path
inside the already-running Pi before invoking the extension factory.

## Hard activation gate

**Do not merge/deploy this Fort branch and do not restart or stop
`familiar-instance-presence` until Kevin controls the sequence.** The safe
sequence is:

1. Merge/build the Familiar change above, but do not restart Presence. Its
   tracked fetch may restart `familiar-instance.service`; that outer unit does
   not own or restart Presence.
2. Have current Exo schedule a durable wake using the existing wake extension.
3. Only after the wake is durable, deploy this Fort generation with an operator
   path that honors `restartIfChanged=false` and `stopIfChanged=false`. Inspect
   the activation diff first; reject any job for
   `familiar-instance-presence.service`.
4. Let `fort-tracked-familiar-ui-fetch.service` build the private repo. Its only
   restart edges are `familiar-ui-stage.service` and
   `familiar-ui-broker.service`. It must never name Presence.
5. Verify the stage unit added `/etc/familiar-ui-extension/index.js` to the live
   Pi settings, then Kevin manually runs `/reload` in current Presence.
6. Kevin explicitly confirms he had the opportunity to run `/reload` and that
   the durable wake exists. Until that confirmation, current Exo must not
   self-restart and no operator may restart/stop Presence.
7. After confirmation only, current Exo may deliberately restart
   `familiar-instance-presence`. Verify the new pane is owned by the dedicated
   Presence cgroup, the extension remains in settings after birth, the bridge
   listens only on `127.0.0.1:8795`, and the descriptor is 0600 under `/run`.

Activation/restart edges: nginx may reload/restart for the vhost;
`familiar-ui-broker` may start/restart; `familiar-ui-stage` may run; the tracked
Familiar update may restart only `familiar-instance.service`. None of those may
propagate to Presence. The Fort assertions and explicit lifecycle flags guard
both tracked-update and Nix switch edges.
