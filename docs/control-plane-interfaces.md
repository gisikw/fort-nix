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
    # Exit 0 if the credential was successfully received/stored
    # Exit non-zero only if the credential itself is bad or couldn't be stored
    # (downstream failures like service restart don't affect exit code)

    payload=$(cat)
    echo "$payload" | jq -r '.client_secret' > /var/lib/outline/oidc-secret
    systemctl reload outline || true  # Credential is fine even if reload fails
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
  handler = ./handlers/oidc-reconcile.sh;
  triggers.initialize = true;
};

fort.host.capabilities.git = {
  handler = ./handlers/git-reconcile.sh;
  cacheResponse = true;
  triggers.initialize = true;
};

fort.host.capabilities.ssl = {
  handler = ./handlers/ssl-reconcile.sh;
  triggers = {
    initialize = true;
    systemd = [ "acme.service" ];  # Re-run when ACME renews
  };
};

fort.host.capabilities.journal = {
  handler = ./handlers/journal.sh;
  allowed = [ "dev-sandbox" ];
  mode = "rpc";  # Direct request-response, no orchestration
};
```

The capability name (`oidc`) corresponds directly to the need type. Exposed at `/agent/capabilities/oidc`.

**Capability options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `handler` | path | required | Script to invoke |
| `allowed` | list | `[]` | Additional callers beyond needers |
| `mode` | `"rpc"` | (async) | RPC = direct request-response, no orchestration |
| `cacheResponse` | bool | `false` | Persist responses for handler to reuse |
| `triggers.initialize` | bool | `false` | Run on boot with all known state |
| `triggers.systemd` | list | `[]` | Systemd units that trigger re-run |

**Access control**: Permitted callers = `allowed` list ++ hosts that declare `fort.host.needs.<capability>.*`.

**RPC mode**: When `mode = "rpc"`, the agent invokes the handler and returns its output directly. No callbacks, no state, no GC - just request-response. Used for operational endpoints like `journal`, `restart`, `status`.

### Handler Contract

Handlers receive **all active requests** (with cached responses if available) and return **all responses**:

**Input** (stdin):
```json
{
  "joker:oidc/outline": {
    "request": { "client_name": "outline", "redirect_uris": [...] },
    "response": { "client_id": "xxx", "client_secret": "yyy" }
  },
  "ursula:oidc/grafana": {
    "request": { "client_name": "grafana", "redirect_uris": [...] },
    "response": null
  }
}
```

**Output** (stdout):
```json
{
  "joker:oidc/outline": { "client_id": "xxx", "client_secret": "yyy" },
  "ursula:oidc/grafana": { "client_id": "zzz", "client_secret": "www" }
}
```

The handler:
- Receives all active needs for this capability
- Sees existing responses (if `cacheResponse` is set) - can reuse or regenerate
- Returns responses for all needs
- Can perform cleanup (entries missing from input = needs that went away)

The handler doesn't know or care about callback routing - that's orchestration's job.

### Handler Contract (RPC Mode)

RPC handlers receive a single request and return a single response:

**Input** (stdin):
```json
{ "unit": "nginx", "lines": 50 }
```

**Output** (stdout):
```json
{ "logs": "..." }
```

No state, no callbacks - just request-response.

### Provider Orchestration

The orchestration layer manages the lifecycle around handlers:

**On new request:**
1. Validate signature and authorization
2. Add request to provider state
3. Invoke handler with all requests for this capability
4. Update state with responses
5. Send callbacks to all origins with their responses (fire-and-forget)
6. Return HTTP 202 to original request

**On boot** (if `triggers.initialize = true`):
1. Load provider state from disk
2. Invoke handler with all known requests
3. Send callbacks to all origins

**On systemd trigger** (if `triggers.systemd` specified):
1. Invoke handler with all known requests
2. Compare responses to cached values
3. Send callbacks only where response changed

**Provider state** (`/var/lib/fort/provider-state.json`):
```json
{
  "oidc": {
    "joker:oidc/outline": {
      "request": { "client_name": "outline", ... },
      "response": { "client_id": "xxx", "client_secret": "yyy" },
      "updated_at": 1704672005
    }
  },
  "proxy": {
    "joker:proxy/outline": {
      "request": { "vhost": "outline.example.com", ... },
      "updated_at": 1704672005
    }
  }
}
```

Responses are persisted only if `cacheResponse = true`. The handler decides whether to reuse cached responses or regenerate.

### Rotation and Reconciliation

Nags are a **resiliency mechanism**, not the primary trigger. Rotation happens via:

1. **Systemd triggers** (`triggers.systemd`): ACME renews → handler re-runs → changed certs sent to consumers
2. **GC sweep**: Periodic GC invokes handler with current state, which also serves as reconciliation
3. **Request-driven**: New request triggers full handler invocation, may update other consumers

Handlers are responsible for their own diff logic - the orchestrator just passes all state and dispatches whatever comes back.

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

### GC Sweep

Provider periodically:

1. For each origin in provider state, query `POST /agent/needs`
2. For entries where `need` is not in the response:
   - If host responded: remove from provider state
   - If host unreachable: skip (don't delete on network failure)
3. Invoke handler with updated state (now excludes removed entries)
4. Handler cleans up artifacts for missing entries

**Positive absence**: Only delete when we get a positive response that doesn't include the need. Network failures are not evidence of abandonment.

### Host Decommissioning

When a host is removed from the cluster, it's a build-time change that triggers a deploy. GC sweep will see the host is no longer in the build-time host list and clean up entries for that origin.

### Side-Effect-Only Needs

For needs where the consumer doesn't receive/use a credential (just triggers a side effect on provider):

```nix
fort.host.needs.proxy.outline = {
  from = "raishan";
  request = { vhost = "outline.example.com"; upstream = "joker:3000"; };
  nag = "1h";
  # No handler - callback payload is interpreted as status (OK or empty)
};
```

When no handler is specified, the callback payload is interpreted as a status:
- `OK`: satisfied, stop nagging
- empty: unsatisfied/revoked, will nag after interval

The need existing in `/agent/needs` is what keeps the proxy vhost alive. Provider can "revoke" by sending empty payload, triggering re-request.

---

## State Summary

| Component | State | Location |
|-----------|-------|----------|
| Consumer: declared needs | `/etc/fort/needs.json` | Build-time, read-only |
| Consumer: fulfillment state | `/var/lib/fort/fulfillment-state.json` | `{need_id → {satisfied, last_sought}}` |
| Provider: capability state | `/var/lib/fort/provider-state.json` | `{capability → {origin:need → {request, response?, updated_at}}}` |
