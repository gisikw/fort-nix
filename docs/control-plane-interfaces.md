# Control Plane Interfaces

This document defines the interfaces for the fort-nix control plane. It focuses on contracts between components, not implementation details.

## Design Principles

1. **Fire-and-forget communication** - Neither consumer nor provider tracks delivery acknowledgment
2. **Nag-based reliability** - Consumers periodically re-request unsatisfied needs; eventual consistency within nag interval
3. **Single code path** - Initial fulfillment and rotation use the same callback mechanism
4. **Build-time knowledge** - Provider locations and capability types are known at build time
5. **Consumer advertises needs, not handles** - Provider tracks handles internally for GC

---

## Consumer Side

### Declaring a Need

Apps declare needs in their Nix module:

```nix
fort.host.needs.oidc.outline = {
  from = "drhorrible";
  request = {
    client_name = "outline";
    redirect_uris = [ "https://outline.example.com/auth/callback" ];
  };
  nag = "15m";
};
```

| Field | Type | Description |
|-------|------|-------------|
| `from` | hostname | Provider host that serves this capability |
| `request` | attrset | Capability-specific request payload |
| `nag` | duration | Period of acceptable absence - re-request if unsatisfied for this long |

The need is identified by `<type>.<id>` (e.g., `oidc.outline`):
- `<type>` maps directly to the capability name on the provider (`/agent/capabilities/oidc`)
- `<id>` distinguishes multiple needs of the same type on one host
- The callback endpoint is derived from both: `/agent/needs/oidc/outline`

### Declaring a Callback Handler

The callback handler is invoked when the provider fulfills the need:

```nix
fort.host.needs.oidc.outline = {
  # ... need declaration ...
  handler = pkgs.writeShellScript "oidc-outline-callback" ''
    # Receives payload on stdin (format depends on capability - could be JSON, could be binary)
    # Should:
    # 1. Store/apply the credential
    # 2. Reload/restart dependent services if needed
    # 3. Exit 0 on success

    payload=$(cat)
    echo "$payload" | jq -r '.client_secret' > /var/lib/outline/oidc-secret
    systemctl reload outline
  '';
};
```

Callback handlers must be **idempotent** - calling with the same payload multiple times should be safe.

### Needs Aggregation (Build Time)

At build time, all `fort.needs.*` declarations across enabled apps/aspects are collected into `/etc/fort/needs.json`:

```json
{
  "oidc/outline": {
    "from": "drhorrible",
    "request": {
      "client_name": "outline",
      "redirect_uris": ["https://outline.example.com/auth/callback"]
    },
    "nag_seconds": 900
  },
  "ssl/outline": {
    "from": "drhorrible",
    "request": {
      "domain": "outline.example.com"
    },
    "nag_seconds": 3600
  }
}
```

The capability is derived from the need type: `oidc/outline` → `/agent/capabilities/oidc`.

### Fulfill Service (Runtime)

`fort-fulfill.service` runs on a timer and:

1. Reads `/etc/fort/needs.json`
2. Reads `/var/lib/fort/fulfillment-state.json` (tracks `{need_id → {satisfied, last_sought}}`)
3. For each need where `!satisfied && (now - last_sought) > nag_seconds`:
   - Updates `last_sought` to now
   - Sends request to provider (fire-and-forget)
4. Logs results but doesn't update `satisfied` (callback updates that)

### Callback Invocation

When the provider calls back:

1. Agent receives `POST /agent/needs/<type>/<name>` with payload
2. Agent invokes the callback handler script with payload on stdin
3. If handler exits 0, agent sets `satisfied = true` for that need
4. If handler exits non-zero, `satisfied` remains false (nag will retry)

A null/empty callback (revocation) sets `satisfied = false`, triggering re-request after nag interval.

**Security**: The callback endpoint rejects requests from any origin other than the provider specified in the need declaration.

### Needs Enumeration

`POST /agent/needs` returns all active need paths this host is listening for:

```json
{
  "needs": [
    "oidc/outline",
    "ssl/outline",
    "proxy/outline"
  ]
}
```

This is deterministic from the Nix config - it's just the keys of `/etc/fort/needs.json`. Providers use this for GC (see Reconciliation).

---

## Provider Side

### Declaring a Capability

Providers declare capabilities in their Nix module:

```nix
fort.host.capabilities.oidc = {
  handler = ./handlers/oidc-handler.sh;
};

fort.host.capabilities.journal = {
  handler = ./handlers/journal.sh;
  allowed = [ "dev-sandbox" ];  # Additional callers beyond needers
  immediate = true;             # Synchronous RPC, no orchestration
};
```

The capability name (`oidc`) corresponds directly to the need type. Exposed at `/agent/capabilities/oidc`.

**Access control**: Permitted callers = `allowed` list ++ hosts that declare `fort.host.needs.<capability>.*`. The `allowed` field adds extra callers (e.g., principals like `dev-sandbox`) beyond the implicit needer set.

**Immediate capabilities**: When `immediate = true`, the agent invokes the handler and returns its output directly. No callbacks, no handles, no GC - just synchronous request-response. Used for operational endpoints like `journal`, `restart`, `status`.

### Handler Contract

Handlers receive request details and must produce a response:

**Input** (environment variables + stdin):
```bash
FORT_ORIGIN="joker"              # Requesting host
FORT_NEED="oidc/outline"         # Need path (for callback routing)
# stdin contains the request payload JSON
```

**Output** (stdout):
```json
{
  "client_id": "outline-client-id",
  "client_secret": "secret-value"
}
```

The handler just returns the payload to deliver. It doesn't manage handles - the provider orchestrator handles that.

The handler is responsible for:
1. Processing the request (creating OIDC client, generating cert, etc.)
2. Returning the payload to send to the consumer

### Capability Dispatch

When agent receives a fulfillment request:

1. Validates signature and authorization
2. Invokes capability handler
3. Generates handle (e.g., `sha256(origin + need + request + response)`)
4. Records `{handle → {origin, need, artifact}}` in provider state
5. Sends callback to `POST /agent/needs/<need-path>` on origin host (fire-and-forget)
6. Returns HTTP 202 to original request (informational only)

### Provider-Initiated Rotation

When a provider needs to rotate credentials (cert renewal, key rotation, etc.):

1. Provider's internal logic determines rotation is needed (e.g., ACME cron)
2. Provider looks up affected handles and their origin hosts/needs
3. Provider sends callback with new payload (push model)

Nags are a **resiliency mechanism**, not the primary rotation trigger. We optimize for true rotation (provider pushes new credentials) and use revocation (empty callback) only when truly necessary.

The orchestration layer (not the handler) is responsible for:
- Tracking which origins/needs have been fulfilled
- Initiating callbacks when rotation is needed
- Reconstructing this state at boot from persistent storage

---

## Wire Protocol

### Fulfillment Request

Consumer → Provider:

```
POST /agent/capabilities/oidc HTTP/1.1
Host: drhorrible.fort.example.com
X-Fort-Origin: joker
X-Fort-Timestamp: 1704672000
X-Fort-Signature: <ssh-signature>
Content-Type: application/json

{
  "need": "oidc/outline",
  "request": {
    "client_name": "outline",
    "redirect_uris": ["https://outline.example.com/auth/callback"]
  }
}
```

Response (informational, consumer ignores):
```
HTTP/1.1 202 Accepted
```

### Callback

Provider → Consumer:

```
POST /agent/needs/oidc/outline HTTP/1.1
Host: joker.fort.example.com
X-Fort-Origin: drhorrible
X-Fort-Timestamp: 1704672005
X-Fort-Signature: <ssh-signature>
Content-Type: application/json

{
  "client_id": "outline-client-id",
  "client_secret": "secret-value"
}
```

Payload is passed directly to handler stdin. Could be JSON, could be binary (e.g., cert PEM).

Response (informational, provider ignores):
```
HTTP/1.1 200 OK
```

### Needs Enumeration

Requester → Host:

```
POST /agent/needs HTTP/1.1
...

{}
```

Response:
```json
{
  "needs": [
    "oidc/outline",
    "ssl/outline",
    "proxy/outline"
  ]
}
```

---

## Reconciliation and GC

### Provider State

Each provider maintains:
```json
{
  "handles": {
    "h_<sha256>": {
      "origin": "joker",
      "need": "oidc/outline",
      "created_at": 1704672005,
      "artifact": { /* provider-specific: client ID, cert serial, etc. */ }
    }
  }
}
```

The capability is derived from the need (`oidc/outline` → `oidc`). Handle could be `sha256(origin + need + request + response)` or similar - just needs to be stable for the same fulfillment and change when the artifact changes.

### GC Sweep

Provider periodically:

1. Groups handles by origin host
2. For each origin host, queries `POST /agent/needs`
3. For handles where `need` is not in the response:
   - If host responded: need is gone, clean up artifact
   - If host unreachable: skip (don't delete on network failure)

**Positive absence**: Only delete when we get a positive response that doesn't include the need. Network failures are not evidence of abandonment.

### Host Decommissioning

When a host is removed from the cluster, it's a build-time change that triggers a deploy. GC sweep will see the host is no longer in the build-time host list and clean up handles for that origin.

---

## Open Questions

### 1. Handle Generation

Who generates handles and how?

- **Handler generates**: Handler knows its artifacts, can create meaningful IDs
- **Orchestrator generates**: Hash of (origin, need, request, response), handler stays simple

Leaning toward orchestrator generates, keeps handlers focused on business logic.

### 2. GC-Only Needs (Proxy Vhosts)

For needs where the consumer doesn't receive/use a credential (just triggers a side effect on provider):

```nix
fort.host.needs.proxy.outline = {
  from = "raishan";
  request = { vhost = "outline.example.com"; upstream = "joker:3000"; };
  nag = "1h";
  # No handler - callback payload is interpreted as exit code
};
```

When no handler is specified, the callback payload is interpreted as an exit code:
- `0` (or empty): satisfied, stop nagging
- `1`: unsatisfied, will nag after interval

The need existing in `/agent/needs` is what keeps the proxy vhost alive. Provider can "revoke" by sending `1`, triggering re-request.

---

## State Summary

| Component | State | Location |
|-----------|-------|----------|
| Consumer: declared needs | `/etc/fort/needs.json` | Build-time, read-only |
| Consumer: fulfillment state | `/var/lib/fort/fulfillment-state.json` | `{need_id → {satisfied, last_sought}}` |
| Provider: handle mappings | `/var/lib/fort/provider-state.json` | `{handle → {origin, need, artifact}}` |
