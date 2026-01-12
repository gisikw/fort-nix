# Fort Control Plane Design

Technical design for inter-host coordination.

---

# Part 1: Agent Architecture

The **agent** is a generic capability-exposure mechanism. Every host runs one. It's how hosts talk to each other.

## Core Concept

Every host exposes an HTTP API at `https://<host>.fort.<domain>/fort/`. Capabilities are endpoints. Access is controlled by origin-based RBAC computed at eval time.

```
┌─────────────────────────────────────────────────────────────────┐
│                         Eval Time (Nix)                         │
│                                                                 │
│  Host config includes:                                          │
│    - What capabilities I expose (handlers in /etc/fort/)  │
│    - Who can call each capability (RBAC from cluster topology)  │
│                                                                 │
│  This is COMPUTED, not configured. Nix knows everything.        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ deployed to host
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Host Agent                              │
│                                                                 │
│  POST /fort/<capability>                                       │
│    - Verify caller identity (SSH signature)                     │
│    - Check RBAC (is caller allowed to invoke this?)             │
│    - Dispatch to handler script                                 │
│    - Return response with optional handle/ttl headers           │
│                                                                 │
│  That's it. The agent is a authenticated RPC mechanism.         │
└─────────────────────────────────────────────────────────────────┘
```

## Mandatory Endpoints

Every agent exposes these (no RBAC, cluster-internal only):

| Endpoint | What It Does |
|----------|--------------|
| `POST /fort/status` | Returns health, uptime, version |
| `POST /fort/manifest` | Returns this host's declared configuration |
| `POST /fort/holdings` | Returns handles this host is currently using |
| `POST /fort/release` | Release handles, trigger GC (see below) |

### The Release Endpoint

Two modes with different auth:

**Self-release (no RBAC):** Host announces it's done with handles.
```http
POST /fort/release
{ "handles": ["sha256:abc...", "sha256:def..."] }  # Specific handles
{ "handles": [] }                                   # "Re-check my holdings now"
{ "handles": [...], "force": "ignore-grace" }       # Skip grace period (fresh boot, lost state)
```
Removes handles from holdings, notifies relevant providers.

**Admin sweep (RBAC: admin only):** Trigger cluster-wide GC.
```http
POST /fort/release
{ "scope": "cluster" }                             # Sweep all hosts
{ "scope": "cluster", "force": "ignore-grace" }    # Skip grace period
{ "scope": "cluster", "force": "gc-unreachable" }  # Include unreachable hosts
```
For emergency rotation when credentials may be compromised.

## Custom Capabilities

Hosts declare additional capabilities based on their role. These are just handler scripts:

```
/etc/fort/handlers/
├── status              # Mandatory
├── manifest            # Mandatory
├── holdings            # Mandatory
├── oidc-register       # Forge only
├── proxy-configure     # Beacon only
├── backup-accept       # NAS only
└── journal-tail        # Maybe everyone?
```

The agent doesn't know or care what these do. It just does auth, checks RBAC, and dispatches.

## Protocol

**All requests are POST.** Even queries. Simplifies everything.

**Request:**
```http
POST /fort/some-capability HTTP/1.1
Host: drhorrible.fort.gisi.network
X-Fort-Origin: ursula
X-Fort-Timestamp: 1704067200
X-Fort-Signature: <signature of body with ursula's SSH key>
Content-Type: application/json

{ "service": "outline", ... }
```

**Response:**
```http
HTTP/1.1 200 OK
X-Fort-Handle: sha256:9f86d08...
X-Fort-TTL: 86400
Content-Type: application/json

{ "client_id": "...", "client_secret": "..." }
```

**Handle and TTL are headers**, not body fields. This:
- Keeps protocol metadata separate from capability-specific content
- Works for non-JSON responses (binary, streaming)
- Lets handlers ignore the holdings protocol entirely if they don't need it

## Holdings Protocol

Some capabilities create server-side state that should be garbage-collected when no longer needed. The holdings protocol handles this.

**Contract:**
1. Provider returns `X-Fort-Handle` header with response
2. Caller stores the handle and returns it from `/fort/holdings`
3. Provider periodically checks holdings; if handle absent (with 200 response), eligible for GC

**GC Rules (Two Generals Safe):**
```
GET /holdings returns 200, handle absent  → eligible for GC (after grace period)
GET /holdings returns 200, handle present → still in use
GET /holdings fails (timeout, 5xx, etc.)  → assume still in use
Host removed from cluster manifest        → immediate GC
```

We only revoke on **positive absence**, never on failure to reach.

## RBAC

Computed at eval time from cluster topology:

```nix
# Written to /etc/fort/rbac.json
{
  "oidc-register": ["ursula", "joker", "lordhenry"],
  "proxy-configure": ["ursula", "minos"],
  "backup-accept": ["*"],  # Any cluster host
}
```

The manifest IS the authorization. Handlers assume the caller is already validated.

## Implementation

CGI-style handlers behind nginx:

```nginx
location /fort/ {
    # Auth + RBAC checked by fcgi wrapper
    fastcgi_pass unix:/run/fort/fcgi.sock;
    fastcgi_param SCRIPT_NAME $uri;
}
```

Handler scripts receive validated requests, return responses. The wrapper adds `X-Fort-Handle` if the handler provides one.

## Design Decisions

**Two god nodes, separated by concern:**
- **Forge** (drhorrible): Identity & secrets - OIDC registration, SSL certs, git tokens
- **Beacon** (raishan): Network edge - public proxy config, headscale coordination

Beacon must exist as a separate node because it's the publicly addressable VPS. Headscale coordination requires a public IP. Can't collapse into forge without port-level forwarding complexity.

**Deploy resilience:**
Fulfillment is best-effort, not a deploy blocker. `fort-fulfill.service` succeeds even if some needs fail (logs warnings). Services start regardless. Timer retries failed needs. Apps either handle missing creds gracefully or fail to serve auth-gated requests until creds arrive. Non-local dependencies should never block a deploy.

**Egress namespace is orthogonal:**
`inEgressNamespace` is an eval-time concern (network sandboxing for privacy). Not a control plane concern - purely local to the host.

**LDAP groups are app permissions:**
Groups in `sso.groups` control who can access an app via oauth2-proxy, not infrastructure permissions. Orthogonal to control plane except for potential future pocket-id feature (OIDC client restrictions by group - see fort-0rj).

## Open Questions

**Streaming:** For capabilities like journal tailing, what's the transport? Options:
- Return a WebSocket URL to connect to
- Return a bearer token for a separate streaming endpoint
- SSE in the response body (keeps it HTTP)

**Large transfers:** For "please accept this 4GB file", options:
- Handler returns upload URL, caller PUTs directly
- Body streaming (works, but ties up the agent)

These feel like they'd be separate protocols built on top of the agent (agent returns a ticket, you use the ticket elsewhere) rather than extensions to the agent itself.

---

# Part 2: Fulfillment Abstraction

**Fulfillment** is how a host uses the agent channel to resolve its needs at activation time. It's a consumer of the agent, not part of it.

## The Insight

Nix knows what every host needs and where to get it. At eval time, we compute a manifest of needs. At activation time, we fulfill them.

```
┌─────────────────────────────────────────────────────────────────┐
│                       Eval Time (Nix)                           │
│                                                                 │
│  From exposedServices + cluster topology, derive:               │
│    - What I need (OIDC creds, proxy config, SSL cert, etc.)     │
│    - Where to get each thing (which hosts provide it)           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ written to /var/lib/fort/needs.json
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                fort-fulfill.service (on activation)             │
│                                                                 │
│  for each need in needs.json:                                   │
│    if not already fulfilled (handle file exists):               │
│      POST to provider's agent endpoint                          │
│      store response + handle                                    │
│      restart dependent service if specified                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Needs Manifest

```json
// /var/lib/fort/needs.json
[
  {
    "id": "oidc-outline",
    "capability": "oidc-register",
    "providers": ["drhorrible"],
    "request": { "service": "outline" },
    "store": "/var/lib/fort/oidc/outline/",
    "restart": ["outline.service", "oauth2-proxy-outline.service"]
  },
  {
    "id": "proxy-outline",
    "capability": "proxy-configure",
    "providers": ["raishan"],
    "request": { "service": "outline", "upstream": "ursula:4654" },
    "store": null,
    "restart": []
  }
]
```

- **providers**: Array of hostnames - enables failover, load balancing
- **restart**: Array of services to restart after fulfillment

## Storage Layout

```
/var/lib/fort/
├── needs.json              # What we need (from Nix)
├── holdings.json           # Handles we're advertising
├── oidc/
│   └── outline/
│       ├── response.json   # The actual credential data
│       └── handle          # For holdings protocol
└── ssl/
    └── wildcard/
        ├── cert.pem
        ├── key.pem
        └── handle
```

## Fulfillment Logic

```bash
#!/usr/bin/env bash
# fort-fulfill: runs on activation

for need in $(jq -c '.[]' /var/lib/fort/needs.json); do
  id=$(echo "$need" | jq -r '.id')
  handle_file="/var/lib/fort/${id}/handle"

  # Skip if already fulfilled
  [ -f "$handle_file" ] && continue

  # Try providers in order
  for provider in $(echo "$need" | jq -r '.providers[]'); do
    capability=$(echo "$need" | jq -r '.capability')
    request=$(echo "$need" | jq -c '.request')

    if response=$(fort "$provider" "$capability" "$request"); then
      # Store response and handle
      store_dir=$(echo "$need" | jq -r '.store // empty')
      if [ -n "$store_dir" ]; then
        mkdir -p "$store_dir"
        echo "$response" > "$store_dir/response.json"
        # Handle extracted from response headers by fort
        echo "$FORT_HANDLE" > "$store_dir/handle"
        add_to_holdings "$FORT_HANDLE"
      fi

      # Restart dependent service
      restart=$(echo "$need" | jq -r '.restart // empty')
      [ -n "$restart" ] && systemctl restart "$restart"

      break  # Success, don't try other providers
    fi
  done
done
```

Retries, backoff, etc. are implementation details of `fort`, not the fulfillment abstraction.

## Relationship to Agent

The fulfillment service is just a client of the agent API. It's one pattern for using the channel. Other patterns:

- **Ad-hoc calls**: A service directly calls another host's agent for something
- **Timers**: Periodic sync jobs that call agents
- **Triggered**: "When X happens, call Y's agent"

Fulfillment is the most common pattern (resolve needs at activation), but it's not special.

---

# Part 3: Nix Abstractions

The needs manifest and capability handlers shouldn't be hand-written. They emerge from module options.

## Declaring Needs

Services declare what they need via options. The system consolidates these into `needs.json`:

```nix
# apps/outline/default.nix
{
  fort.host.needs.oidc.outline = {
    providers = [ "drhorrible" ];
    request = { service = "outline"; };
    restart = [ "outline.service" ];
  };

  fort.host.needs.proxy.outline = {
    providers = [ "raishan" ];
    request = { service = "outline"; upstream = "${config.networking.hostName}:4654"; };
  };
}
```

The `fort.host.needs` option type handles:
- Generating `/var/lib/fort/needs.json` from all declarations
- Computing store paths consistently
- Validating that referenced providers exist in cluster topology

## Declaring Capabilities

Providers declare what capabilities they expose. The system generates handlers, RBAC, and GC:

```nix
# apps/pocket-id/default.nix
{
  fort.host.capabilities.oidc-register = {
    description = "Register OIDC client in pocket-id";
    handler = ./handlers/oidc-register;  # Script to run
    needsGC = true;                       # Auto-add handle headers, GC timer
    # RBAC computed automatically: hosts that declare fort.host.needs.oidc.*
  };
}
```

When `needsGC = true`, the system:
- Wraps the handler to add `X-Fort-Handle` header to responses
- Tracks issued handles in provider state
- Adds a systemd timer for periodic GC sweeps
- Wires up the holdings-check logic

## RBAC Derivation

RBAC rules are computed, not configured:

```nix
# Pseudo-code for what the module system does:
fortAgent.rbac = {
  "oidc-register" =
    # All hosts that declare any fort.host.needs.oidc.* need
    filter (h: h.config.fort.host.needs.oidc != {}) allHosts;

  "proxy-configure" =
    # All hosts that declare any fort.host.needs.proxy.* need
    filter (h: h.config.fort.host.needs.proxy != {}) allHosts;
};
```

A host can only request what it declares needing. The manifest IS the authorization.

## Benefits

- **Single source of truth**: Apps declare their needs/capabilities, not plumbing
- **Type-safe**: Invalid references caught at eval time
- **Consistent**: Storage paths, restart logic, GC all follow the same pattern
- **Auditable**: `needs.json` and `rbac.json` are readable artifacts

---

# Part 4: Migration & Summary

## Migration Path

1. **Add agent to all hosts** - Mandatory endpoints (`status`, `manifest`, `holdings`, `release`)
2. **Add custom handlers to forge/beacon** - Whatever capabilities they provide
3. **Add `fort-fulfill.service`** - Runs on activation, processes needs.json
4. **Run in parallel** - Both old (SSH push) and new (host pull) work
5. **Validate** - All coordination patterns working
6. **Remove SSH-based delivery** - service-registry aspect, etc.
7. **Enable GC** - Start sweeping orphans

## Summary

**Agent:** Generic capability-exposure mechanism. CGI handlers behind nginx. Auth via SSH signatures, RBAC from cluster topology. All POST. Handle/TTL in response headers.

**Fulfillment:** One pattern for using the agent. Reads needs.json at activation, calls providers, stores results. Just a systemd oneshot, nothing magic.

**Holdings:** Protocol for distributed GC. Providers return handles, callers advertise them. Positive absence triggers cleanup.

The model: hosts are responsible for themselves. Providers serve, they don't orchestrate. No coordinator, no pub/sub, no scanning. Just HTTP calls between hosts that already know about each other.
