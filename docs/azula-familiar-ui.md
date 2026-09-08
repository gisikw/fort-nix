# Azula familiar-ui activation contract

`familiar-ui.gisi.network` is a production static build plus two same-origin
proxy routes into the **existing** `familiar-instance-presence` Pi. It never
starts Pi, uses Pi RPC, or embeds the Pi SDK.

The tracked package follows familiar-ui `main`. The production/security
contract consumed here is commit `48a2e3fe928cf3c0211dd09e088a2932c5862b4b` or
later with those semantics.

## Trust boundaries

- nginx serves only the tracked profile's immutable `web/` output. It receives
  no bind mount into `/home` or `/var/lib/kestrel`.
- Static content, `/__familiar/bridge.json`, and `/v1/` remain behind the same
  identity SSO wall. The browser's HttpOnly SSO cookie terminates at nginx and
  is stripped from both upstreams. Authorization is stripped from the broker
  route and passed only to `/v1/`, where it is the independent, per-session
  bridge bearer. The internal identity-validation subrequest explicitly clears
  Authorization so it cannot mistake that bridge bearer for an OIDC bearer;
  this browser lane authenticates there solely with the SSO cookie.
- The in-process extension binds `127.0.0.1:8795`. nginx rewrites the upstream
  `Host` to exactly `127.0.0.1:8795`; the bridge independently checks Host, the
  exact configured origin for state-changing requests, and the bearer.
  Originless same-origin HTTPS reads remain bearer- and Host-protected.
- `/__familiar/bridge.json` is identity-authenticated and proxied over
  `/run/familiar-ui/broker.sock`. The broker runs with UID `familiar` and group
  `nginx`, validates the shared 0750 runtime directory and the 0600 regular
  descriptor through one `O_NOFOLLOW` file descriptor, validates
  origin/loopback port/version, strips process metadata, and rewrites only
  `url` to the public same origin. nginx can traverse to the 0660 socket but
  cannot read the descriptor file.
- The token is `no-store`, never a URL, cookie, Nix value, nginx argument, or
  log field. This vhost uses a dedicated access format whose request portion is
  only `$request_method $uri`; normalized `$uri` excludes arguments. The format
  contains no Authorization field, `$args`, `$request`, or `$request_uri`.
  Its server-level error log is pinned to `warn`, never `debug`, so nginx cannot
  emit request headers through debug logging. One server block owns both TLS
  and cleartext listeners, ensuring the dedicated logs also cover HTTP; its
  HTTPS redirect uses a literal origin and deliberately drops the requested
  path and all arguments rather than reflecting attacker-controlled data.
- Both custom proxy locations explicitly disable NixOS
  `recommendedProxySettings`. The common nginx module enables those defaults
  globally, but inheriting them would append a second `Host $host` after each
  boundary's deliberate Host header. The descriptor sends exactly the public
  Host; `/v1/` sends exactly `Host 127.0.0.1:8795` for the bridge's
  DNS-rebinding check.
- `/v1/` explicitly uses HTTP/1.1, an empty upstream `Connection` header, and
  disables proxy buffering, proxy caching, and gzip. Combined with the
  bridge's `X-Accel-Buffering: no`, this preserves incremental SSE. The read
  timeout is 600 seconds. Only this location raises the request ceiling, to
  exactly `16842752` bytes (16 MiB + 64 KiB), matching familiar-ui's
  authenticated JSON parser limit; it is bounded, not nginx's `0`/unlimited.
  The descriptor, static, and identity locations do not receive this override.
- Request buffering is disabled only for `/v1/`. nginx performs
  `auth_request` in the access phase before the proxy content handler starts
  reading and forwarding the client body, and `client_max_body_size` remains
  active as nginx reads fixed-length or chunked bodies. Streaming therefore
  avoids staging a roughly 16 MiB base64 JSON request in nginx's client-body
  temp area without exposing the loopback bridge to unauthenticated body bytes
  or relaxing the byte limit. Response-side `proxy_buffering off` remains a
  separate SSE requirement.
- This host's public traffic first crosses the generic public-ingress nginx,
  whose canonical NixOS `services.nginx.clientMaxBodySize` is deliberately
  generous (`100m`) so the edge does not preempt backend policy. Fort's
  per-service `maxBodySize` abstraction can add a backend location override,
  but familiar-ui is a static service with multiple trust-boundary locations;
  its precise limit therefore belongs directly on `^~ /v1/`. The edge ceiling
  does not supersede this tighter location-level limit.
- A Pi reload creates a new extension runtime, epoch, and token. Existing
  action ids, session ids, and cursors retain familiar-ui's stale/reset
  semantics. A stale browser waits for the replacement descriptor after a 401
  and reloads itself.

## Pi extension staging and profile updates

Kestrel's `familiar.toml` is under `/var/lib/kestrel`; Familiar consequently
sets `STATE_DIR=/var/lib/kestrel/state` and exports the actual
`PI_CODING_AGENT_DIR=/var/lib/kestrel/state/pi`.

Pi 0.84 documents `$PI_CODING_AGENT_DIR/extensions/*/index.js` as a global,
auto-discovered extension location compatible with `/reload`. The stateless
`familiar-ui-stage.service` therefore creates:

```text
/var/lib/kestrel/state/pi/extensions/familiar-ui/index.js
```

as a symlink to the declarative wrapper. The same stateless stage creates the
private parent directory `/var/lib/kestrel/state/plate` as `familiar:users`
mode `0700`, but never creates, reads, truncates, or otherwise touches
`plate.json`. The Plate itself can consequently remain durable and private at
`/var/lib/kestrel/state/plate/plate.json`.

Staging does **not** read or mutate `settings.json`, avoiding races with Pi's
own `proper-lockfile` settings persistence. This auto-discovered location is
rescanned by `/reload` and is present on the next Presence birth, so
`FAMILIAR_PI_EXTRA_EXTENSIONS_JSON` is not needed. The wrapper is deliberately
absent from explicit Pi settings, which prevents loading the same extension
once by auto-discovery and once by settings.

The wrapper's default factory is async. Before importing familiar-ui it sets
`FAMILIAR_UI_ORIGIN`, `FAMILIAR_UI_PORT`, `FAMILIAR_UI_DESCRIPTOR`, and the
canonical `FAMILIAR_PLATE_FILE=/var/lib/kestrel/state/plate/plate.json`. It does
not set display names; `FAMILIAR_USER_NAME` and `FAMILIAR_AGENT_NAME` remain
inherited from Presence when configured through `familiar.toml`. It then uses
`realpath()` on the extension beneath the mutable tracked profile,
requires the result to be in `/nix/store/`, converts that immutable target with
`pathToFileURL()`, dynamically imports it, and invokes its default factory.
Each `/reload` therefore gets the current profile generation rather than a
cached module reached through the stable profile symlink.

Package updates may restart only `familiar-ui-stage.service` and
`familiar-ui-broker.service`. Staging merely refreshes the wrapper symlink; it
does not signal Pi. The new code becomes live only when Kevin explicitly runs
`/reload`.

## Hard activation gate

**Do not merge/deploy this Fort branch and do not restart or stop
`familiar-instance-presence` until Kevin controls the sequence.** The safe
sequence is:

1. Have current Exo schedule a durable wake using the existing wake extension.
2. Only after the wake is durable, deploy this Fort generation with an operator
   path that honors `restartIfChanged=false` and `stopIfChanged=false`. Inspect
   the activation diff first; reject any job for
   `familiar-instance-presence.service`.
3. Let `fort-tracked-familiar-ui-fetch.service` build reviewed familiar-ui
   `main`. Its only restart edges are `familiar-ui-stage.service` and
   `familiar-ui-broker.service`; it must never name Presence.
4. Verify the stage unit placed the wrapper in the global auto-discovery path,
   without adding it to `settings.json`, then Kevin manually runs `/reload` in
   current Presence.
5. Kevin explicitly confirms he had the opportunity to run `/reload` and that
   the durable wake exists. Until that confirmation, current Exo must not
   self-restart and no operator may restart/stop Presence.
6. After confirmation only, current Exo may deliberately restart
   `familiar-instance-presence`. Verify the new pane is owned by the dedicated
   Presence cgroup, the extension is loaded exactly once, the bridge listens
   only on `127.0.0.1:8795`, and the descriptor is 0600 under the shared 0750
   runtime directory.

Activation/restart edges: nginx may reload/restart for the vhost;
`familiar-ui-broker` may start/restart; `familiar-ui-stage` may run. None of
those may propagate to Presence. The Fort evaluation assertions enforce the
exact bounded `/v1/` body ceiling and its absence from unrelated locations,
request and response buffering policy, SSE/security directives, one
boundary-specific Host header with recommended proxy settings disabled on each
custom location, safe logging format, canonical Plate export, directory-only
private Plate staging, correct Pi auto-discovery path, absence of the duplicate
explicit-extension environment, reviewed branch, and all Presence lifecycle
exclusions.
