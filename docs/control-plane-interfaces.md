# Control Plane Interfaces

This document defines the interfaces for the fort-nix control plane. It focuses on contracts between components, not implementation details.

## Design Principles

1. **Fire-and-forget communication** - Neither consumer nor provider tracks delivery acknowledgment
2. **Nag-based reliability** - Consumers periodically re-request unfulfilled needs; eventual consistency within nag interval
3. **Single code path** - Initial fulfillment and rotation use the same callback mechanism
4. **Build-time knowledge** - Provider locations and capability types are known at build time
5. **Handles for GC only** - Handles exist to enable garbage collection, not for consumer-side lifecycle

---

## Consumer Side

### Declaring a Need

Apps declare needs in their Nix module:

```nix
fort.needs.oidc.outline = {
  from = "drhorrible";
  request = {
    client_name = "outline";
    redirect_uris = [ "https://outline.example.com/auth/callback" ];
  };
  callback = "outline-oidc-updated";
  nag = "15m";
};
```

| Field | Type | Description |
|-------|------|-------------|
| `from` | hostname | Provider host that serves this capability |
| `request` | attrset | Capability-specific request payload |
| `callback` | string | Handler name on this host to receive fulfillment |
| `nag` | duration | Re-request if not fulfilled within this interval |

The need is identified by `<type>.<name>` (e.g., `oidc.outline`). This forms a stable need ID.

### Declaring a Callback Handler

The callback handler is invoked when the provider fulfills the need:

```nix
fort.callbacks.outline-oidc-updated = {
  handler = pkgs.writeShellScript "outline-oidc-updated" ''
    # Receives JSON on stdin: { handle, client_id, client_secret, ... }
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
  "oidc.outline": {
    "from": "drhorrible",
    "capability": "oidc-register",
    "request": {
      "client_name": "outline",
      "redirect_uris": ["https://outline.example.com/auth/callback"]
    },
    "callback": "outline-oidc-updated",
    "nag_seconds": 900
  },
  "ssl.outline": {
    "from": "drhorrible",
    "capability": "ssl-cert",
    "request": {
      "domain": "outline.example.com"
    },
    "callback": "outline-ssl-updated",
    "nag_seconds": 3600
  }
}
```

### Fulfill Service (Runtime)

`fort-fulfill.service` runs on a timer and:

1. Reads `/etc/fort/needs.json`
2. Reads `/var/lib/fort/fulfillment-state.json` (tracks `{need_id → last_fulfilled_at}`)
3. For each need where `now - last_fulfilled_at > nag_seconds`:
   - Sends request to provider (fire-and-forget)
4. Logs results but doesn't update state (callback updates state)

### Callback Invocation

When the provider calls back:

1. Agent receives `POST /agent/<callback-name>` with payload
2. Agent invokes the callback handler script with payload on stdin
3. If handler exits 0, agent updates `last_fulfilled_at` for the corresponding need
4. If handler exits non-zero, state is not updated (nag will retry)

### Holdings

`/agent/holdings` returns all handles this host currently holds:

```json
{
  "handles": [
    { "handle": "h_abc123", "provider": "drhorrible", "capability": "oidc-register" },
    { "handle": "h_def456", "provider": "drhorrible", "capability": "ssl-cert" },
    { "handle": "h_ghi789", "provider": "raishan", "capability": "proxy-config" }
  ]
}
```

Holdings are derived from fulfillment state - each fulfilled need has an associated handle.

---

## Provider Side

### Declaring a Capability

Providers declare capabilities in their Nix module:

```nix
fort.capabilities.oidc-register = {
  handler = ./handlers/oidc-register.sh;
  # Access control is derived from cluster topology
};
```

### Handler Contract

Handlers receive request details and must produce a response:

**Input** (environment variables + stdin):
```bash
FORT_ORIGIN="joker"           # Requesting host
FORT_CALLBACK="outline-oidc-updated"  # Callback handler name
# stdin contains the request payload JSON
```

**Output** (stdout, JSON):
```json
{
  "handle": "h_abc123",
  "payload": {
    "client_id": "outline-client-id",
    "client_secret": "secret-value"
  }
}
```

| Field | Description |
|-------|-------------|
| `handle` | Stable identifier for this fulfillment (for GC) |
| `payload` | Data to send to the consumer's callback |

The handler is responsible for:
1. Processing the request (creating OIDC client, generating cert, etc.)
2. Generating/retrieving a stable handle for this consumer+need combination
3. Returning the payload to send to the consumer

### Capability Dispatch

When agent receives a fulfillment request:

1. Validates signature and authorization
2. Invokes capability handler
3. Records `{handle → origin_host}` mapping in provider state
4. Sends callback to origin host (fire-and-forget)
5. Returns HTTP 202 to original request (informational only)

### Provider-Initiated Rotation

When a provider needs to rotate credentials (cert renewal, key rotation, etc.):

1. Provider's internal logic determines rotation is needed
2. For each affected handle, provider:
   - Generates new credentials
   - Looks up origin host and callback name from handle mapping
   - Sends callback with same handle, new payload

The consumer's callback handler runs, applying the new credentials. Same code path as initial fulfillment.

---

## Wire Protocol

### Fulfillment Request

Consumer → Provider:

```
POST /agent/oidc-register HTTP/1.1
Host: drhorrible.fort.example.com
X-Fort-Origin: joker
X-Fort-Timestamp: 1704672000
X-Fort-Signature: <ssh-signature>
Content-Type: application/json

{
  "callback": "outline-oidc-updated",
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
POST /agent/outline-oidc-updated HTTP/1.1
Host: joker.fort.example.com
X-Fort-Origin: drhorrible
X-Fort-Timestamp: 1704672005
X-Fort-Signature: <ssh-signature>
Content-Type: application/json

{
  "handle": "h_abc123",
  "client_id": "outline-client-id",
  "client_secret": "secret-value"
}
```

Response (informational, provider ignores):
```
HTTP/1.1 200 OK
```

### Holdings Query

Requester → Host:

```
POST /agent/holdings HTTP/1.1
...

{}
```

Response:
```json
{
  "handles": [
    { "handle": "h_abc123", "provider": "drhorrible", "capability": "oidc-register" },
    ...
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
    "h_abc123": {
      "origin": "joker",
      "capability": "oidc-register",
      "callback": "outline-oidc-updated",
      "created_at": 1704672005,
      "artifact": { /* provider-specific: client ID, cert serial, etc. */ }
    }
  }
}
```

### GC Sweep

Provider periodically:

1. Groups handles by origin host
2. For each origin host, queries `/agent/holdings`
3. For handles not present in holdings response:
   - If host responded: handle is orphaned, clean up artifact
   - If host unreachable: skip (don't delete on network failure)

**Positive absence**: Only delete when we get a positive response that doesn't include the handle. Network failures are not evidence of abandonment.

### Consumer Decommissioning

When a host is removed from the cluster:

1. Host stops responding to holdings queries
2. Provider's GC sweep sees "host unreachable"
3. After N consecutive failures (configurable), provider assumes host is gone
4. Provider cleans up all handles for that origin

---

## Open Questions

### 1. Handle Stability Across Rotations

Should rotation reuse the same handle or issue a new one?

- **Same handle**: Simpler consumer state, but provider must track handle→artifact mapping that changes
- **New handle**: Consumer holdings change on rotation, provider can use handle as artifact ID

Leaning toward: **same handle**. The handle identifies the consumer-provider relationship, not the specific credential version.

### 2. Callback Registration

Current design assumes callback name is passed with each request. Alternative: callbacks are registered separately, and requests just reference needs.

Pro of current: Self-contained requests, no registration state
Con of current: Callback name repeated in every request

### 3. Need ID Derivation

How is the stable need ID derived?

- Option A: Explicit `name` field in declaration (current: `fort.needs.oidc.outline`)
- Option B: Hash of (type, from, request)
- Option C: UUID generated at declaration time

Option A seems most ergonomic. Need IDs must be stable across rebuilds for nag logic to work.

### 4. GC-Only Handles (Proxy Vhosts)

For needs where the consumer doesn't receive/use a credential (just triggers a side effect on provider):

```nix
fort.needs.proxy.outline = {
  from = "raishan";
  request = { vhost = "outline.example.com"; upstream = "joker:3000"; };
  callback = "proxy-ack";  # Just records handle, no credential to apply
  nag = "1h";
};
```

The callback handler just needs to exist and succeed. It stores the handle for holdings but doesn't apply any credential.

Should this be a distinct need type, or just a pattern?

### 5. Multi-Provider Needs

Can a single need have multiple providers (failover/load-balance)?

Current design: No. Each need specifies exactly one provider. High availability is the provider's responsibility.

### 6. Nag Interval Guidance

What's the right nag interval for different need types?

| Need Type | Suggested Nag | Rationale |
|-----------|---------------|-----------|
| OIDC credentials | 15m | Rotation rare, quick recovery |
| SSL certs | 1h | Rotation planned, longer buffer ok |
| Git tokens | 30m | Moderate sensitivity |
| Proxy config | 1h | Side-effect only, less urgent |

### 7. Concurrent Callbacks

If provider rotates while consumer's nag request is in flight, consumer might receive two callbacks. Is this a problem?

Callback handlers must be idempotent, so receiving the same or newer credentials twice should be safe. Last-write-wins semantics.

---

## State Summary

| Component | State | Location |
|-----------|-------|----------|
| Consumer: declared needs | `/etc/fort/needs.json` | Build-time, read-only |
| Consumer: fulfillment state | `/var/lib/fort/fulfillment-state.json` | `{need_id → {handle, last_fulfilled_at}}` |
| Provider: handle mappings | `/var/lib/fort/provider-state.json` | `{handle → {origin, callback, artifact}}` |
