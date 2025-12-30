# Fort Control Plane Design

Technical design for unified runtime coordination.

## The Core Insight

In most distributed systems, you need coordination because nodes don't have perfect knowledge. Node A doesn't know Node B exists. Someone has to introduce them.

**We have perfect knowledge at eval time.** Nix knows:
- Every host in the cluster
- Every service on every host
- Every capability and its provider
- The full topology

So there's nothing to coordinate at runtime. The host already knows what it needs and where to get it. Just bake it in and let hosts fetch their own dependencies.

## Architecture

Every host runs an **agent** - a simple HTTP server exposing capabilities. Some capabilities are universal (status, manifest). Others are host-specific (forge exposes `/oidc`, beacon exposes `/proxy`).

```
┌─────────────────────────────────────────────────────────────────┐
│                         Eval Time (Nix)                         │
│                                                                 │
│  Host config includes:                                          │
│    - What services I run                                        │
│    - What each service needs (OIDC, SSL, public proxy, etc.)    │
│    - Where to get each thing (computed from cluster topology)   │
│    - What capabilities I expose (computed from my role)         │
│    - Who can call each capability (RBAC from manifest)          │
│                                                                 │
│  This is COMPUTED, not configured. Nix knows everything.        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ deployed to host
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Host Agent (every host)                      │
│                                                                 │
│  Base endpoints:                                                │
│    GET  /status           - health, uptime                      │
│    GET  /manifest         - this host's declared config         │
│    GET  /holdings         - resources this host is using        │
│                                                                 │
│  Provider endpoints (role-specific):                            │
│    POST /oidc/register    - (forge) register OIDC client        │
│    POST /proxy/configure  - (beacon) configure public proxy     │
│    POST /git/token        - (forge) issue git credentials       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ on activation
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Needs Resolver                             │
│                                                                 │
│  for each unfulfilled need:                                     │
│    call provider's endpoint (with backoff)                      │
│    store result + handle in /var/lib/fort/                      │
│                                                                 │
│  Host drives its own fulfillment. No coordinator needed.        │
└─────────────────────────────────────────────────────────────────┘
```

**Key unification:** There's no separate "provider" vs "agent" concept. Every host runs an agent. Providers are just agents with additional endpoints enabled.

## Two Concerns, Clearly Separated

### 1. Needs Resolution (host-initiated)

The host knows what it needs. On activation, it calls out to providers:

```
ursula (on activation):
  POST drhorrible:agent/oidc/register
    { service: "outline", host: "ursula" }
  → { client_id: "...", client_secret: "...", handle: "sha256:abc123" }

  Writes to /var/lib/fort/oidc/outline/
  Records handle in /var/lib/fort/holdings.json
```

### 2. Capability Exposure (caller-initiated)

Other hosts (or the control plane) can call endpoints you expose:

```
drhorrible (sweeping for orphans):
  GET ursula:agent/holdings
  → ["sha256:abc123", "sha256:def456"]

  Compares against issued handles, GCs unclaimed ones
```

The agent serves both roles through the same HTTP server.

## The Holdings Contract

When a provider fulfills a request, it returns:
- **data** - the credential/resource itself
- **handle** - an opaque identifier (content hash)
- **ttl** - how long until the data expires (optional)

The requester must:
1. Store the handle alongside the data
2. Return it from `GET /holdings` for as long as they're using it
3. Re-request before TTL expires (if TTL was provided)

```
Request:
  POST drhorrible:agent/oidc/register
  { service: "outline", host: "ursula" }

Response:
  {
    "client_id": "outline.ursula",
    "client_secret": "s3cr3t",
    "handle": "sha256:9f86d08...",
    "ttl": 86400
  }

Contract:
  - ursula stores handle in /var/lib/fort/holdings.json
  - ursula's GET /holdings returns ["sha256:9f86d08...", ...]
  - Data is valid for TTL seconds AND as long as handle is advertised
  - ursula should re-request before TTL expires to refresh
```

### GC Rules (Two Generals Safe)

The provider can only revoke a resource when it gets **positive absence** - a successful 200 from `/holdings` that doesn't include the handle.

```
GC decision matrix:
  GET /holdings returns 200, handle absent  → eligible for GC (after grace period)
  GET /holdings returns 200, handle present → still in use, keep
  GET /holdings fails (timeout, 5xx, etc.)  → assume still in use, keep
  Host not in cluster manifest              → eligible for immediate GC
```

This avoids the two generals problem: we never revoke because we *couldn't* confirm, only when we *positively* confirm absence. Dead/unreachable hosts keep their resources until either:
- They come back and stop advertising the handle
- They're removed from the cluster manifest (deploy-time cleanup)

## Authentication & Authorization

### Identity: SSH Keys

Hosts already have SSH keypairs. Requests are signed with the host's private key:

```
POST /oidc/register
X-Fort-Host: ursula
X-Fort-Signature: <signature of request body with ursula's key>
X-Fort-Timestamp: 1704067200
```

Provider verifies:
1. Signature matches claimed host's public key (from cluster config)
2. Timestamp is recent (replay protection)

### Authorization: Declarative RBAC

Nix computes who can call what. Providers load this at startup:

```nix
# Computed at eval time, written to provider's config
fortAgent.rbac = {
  "/oidc/register" = {
    # Hosts that declare services with sso.mode = "oidc"
    allowedCallers = [ "ursula" "joker" "lordhenry" ];
  };
  "/proxy/configure" = {
    # Hosts that declare services with visibility = "public"
    allowedCallers = [ "ursula" "minos" ];
  };
};
```

The manifest IS the authorization. No runtime policy engine needed.

## Storage Layout

All runtime state under `/var/lib/fort/`:

```
/var/lib/fort/
├── holdings.json           # Handles we're using (for GC protocol)
├── manifest.json           # Our declared config (served by agent)
├── oidc/
│   └── outline/
│       ├── client-id
│       ├── client-secret
│       └── handle          # The handle for this credential
├── ssl/
│   └── outline/
│       ├── cert.pem
│       ├── key.pem
│       └── handle
└── git/
    └── token
```

This coexists with agenix for static secrets. Agenix handles secrets known at build time (API keys, passwords). This handles secrets that require runtime registration (OIDC clients, SSL certs).

## Activation Flow

```bash
#!/usr/bin/env bash
# fort-fulfill: runs on host activation

set -euo pipefail
FORT_DIR="/var/lib/fort"
HOLDINGS="$FORT_DIR/holdings.json"

# Initialize holdings if missing
[ -f "$HOLDINGS" ] || echo '[]' > "$HOLDINGS"

sign_request() {
  local body="$1"
  local timestamp=$(date +%s)
  local to_sign="${timestamp}:${body}"
  local sig=$(echo -n "$to_sign" | ssh-keygen -Y sign -f /etc/ssh/ssh_host_ed25519_key -n fort-agent 2>/dev/null | base64 -w0)
  echo "-H 'X-Fort-Host: $HOSTNAME' -H 'X-Fort-Timestamp: $timestamp' -H 'X-Fort-Signature: $sig'"
}

fetch_with_backoff() {
  local url="$1"
  local body="$2"
  local output="$3"
  local headers=$(sign_request "$body")

  for attempt in {1..10}; do
    if eval "curl -sf $headers -d '$body' '$url'" > "$output"; then
      return 0
    fi
    echo "Attempt $attempt failed, retrying in $((2 ** attempt))s..."
    sleep $((2 ** attempt))
  done
  return 1
}

add_holding() {
  local handle="$1"
  jq --arg h "$handle" '. + [$h] | unique' "$HOLDINGS" > "$HOLDINGS.tmp"
  mv "$HOLDINGS.tmp" "$HOLDINGS"
}

# Load needs from manifest
needs=$(jq -r '.needs[]' "$FORT_DIR/manifest.json")

for need in $needs; do
  type=$(echo "$need" | jq -r '.type')
  service=$(echo "$need" | jq -r '.service')
  provider=$(echo "$need" | jq -r '.provider')

  cred_dir="$FORT_DIR/$type/$service"
  handle_file="$cred_dir/handle"

  # Skip if already fulfilled
  [ -f "$handle_file" ] && continue

  echo "Fulfilling $type for $service from $provider..."
  mkdir -p "$cred_dir"

  case "$type" in
    oidc)
      body='{"service":"'"$service"'","host":"'"$HOSTNAME"'"}'
      fetch_with_backoff "$provider/oidc/register" "$body" "$cred_dir/response.json"
      jq -r '.client_id' "$cred_dir/response.json" > "$cred_dir/client-id"
      jq -r '.client_secret' "$cred_dir/response.json" > "$cred_dir/client-secret"
      jq -r '.handle' "$cred_dir/response.json" > "$handle_file"
      add_holding "$(cat "$handle_file")"
      rm "$cred_dir/response.json"
      ;;
    # ... other types
  esac
done
```

## Provider Implementation

Providers are just agents with extra endpoints. Example OIDC handler:

```bash
#!/usr/bin/env bash
# Handler for POST /oidc/register

# Auth already verified by agent framework
service="$BODY_service"
host="$BODY_host"
client_name="${service}.${host}"

# Idempotent: check if exists
existing=$(pocket-id-admin get-client "$client_name" 2>/dev/null || true)

if [ -n "$existing" ]; then
  # Return existing (same handle = same content)
  handle=$(echo -n "$client_name" | sha256sum | cut -d' ' -f1)
  echo "$existing" | jq --arg h "sha256:$handle" '. + {handle: $h}'
else
  # Create new
  result=$(pocket-id-admin create-client "$client_name" --format json)
  handle=$(echo -n "$client_name" | sha256sum | cut -d' ' -f1)
  echo "$result" | jq --arg h "sha256:$handle" '. + {handle: $h}'
fi
```

## Garbage Collection

Providers periodically sweep for orphaned resources:

```bash
#!/usr/bin/env bash
# fort-gc: runs on provider (e.g., daily cron)

GRACE_DAYS=7

# Get all issued handles and their creation dates
all_issued=$(pocket-id-admin list-clients --format json)

# Collect holdings from all hosts
all_holdings=()
for host in $CLUSTER_HOSTS; do
  holdings=$(curl -sf "$host:agent/holdings" || echo '[]')
  all_holdings+=( $(echo "$holdings" | jq -r '.[]') )
done

# Sweep
for client in $(echo "$all_issued" | jq -r '.[].name'); do
  handle="sha256:$(echo -n "$client" | sha256sum | cut -d' ' -f1)"

  if ! printf '%s\n' "${all_holdings[@]}" | grep -q "^$handle$"; then
    age_days=$(client_age_days "$client")
    if [ "$age_days" -gt "$GRACE_DAYS" ]; then
      echo "GC: deleting orphaned client $client (unclaimed for $age_days days)"
      pocket-id-admin delete-client "$client"
    fi
  fi
done
```

## Manifest Shape

```nix
# Written to /var/lib/fort/manifest.json at activation
{
  hostname = "ursula";
  domain = "fort.gisi.network";

  # What this host needs (drives fulfillment)
  needs = [
    {
      type = "oidc";
      service = "outline";
      provider = "https://drhorrible.fort.gisi.network:8443";
      restart = "outline.service";
    }
    {
      type = "proxy";
      service = "outline";
      provider = "https://raishan.fort.gisi.network:8443";
      upstream = "ursula.fort.gisi.network:4654";
    }
  ];

  # What this host exposes (drives agent config)
  capabilities = [
    "status"    # GET /status (all hosts)
    "holdings"  # GET /holdings (all hosts)
    "manifest"  # GET /manifest (all hosts)
  ];

  # RBAC for any provider endpoints (if this host is a provider)
  # rbac = { ... };
}
```

## Failure Handling

**Provider down:** Host retries with exponential backoff. Eventually consistent.

**Activation doesn't block:** Fulfillment runs async. Services start, credentials arrive when ready.

**Deploys are retries:** Redeploy = re-run fulfillment = retry failed requests.

**Host unreachable during GC:** Grace period prevents premature deletion. Host comes back, advertises holdings, resource preserved.

## Migration Path

1. **Add agent to all hosts** - Base endpoints only (`/status`, `/manifest`, `/holdings`)
2. **Add provider endpoints to forge** - `/oidc/register`, `/git/token`
3. **Add provider endpoints to beacon** - `/proxy/configure`
4. **Add fulfillment script** - Runs on activation, requests needs
5. **Run in parallel** - Both old (SSH push) and new (host pull) work
6. **Validate** - All credential types working
7. **Remove SSH-based delivery** - service-registry aspect, etc.
8. **Enable GC** - Start sweeping orphans

## Implementation Notes

### Agent as CGI + nginx

Every host already runs nginx with a vhost at `<host>.fort.<domain>`. The agent is just additional locations on that vhost, backed by CGI scripts:

```nginx
# Generated from host's declared capabilities
location /agent/status {
    fastcgi_pass unix:/run/fort-agent/fcgi.sock;
    fastcgi_param SCRIPT_NAME /status;
}
location /agent/holdings {
    fastcgi_pass unix:/run/fort-agent/fcgi.sock;
    fastcgi_param SCRIPT_NAME /holdings;
}
# Provider endpoints (only on hosts with provider role)
location /agent/oidc/register {
    fastcgi_pass unix:/run/fort-agent/fcgi.sock;
    fastcgi_param SCRIPT_NAME /oidc/register;
}
```

Each endpoint is a script in `/etc/fort-agent/handlers/`:

```
/etc/fort-agent/handlers/
├── status           # GET /agent/status
├── holdings         # GET /agent/holdings
├── manifest         # GET /agent/manifest
└── oidc/
    └── register     # POST /agent/oidc/register (forge only)
```

This is lambdas + API gateway, but with bash scripts and nginx. Benefits:
- Each endpoint is independently testable
- Complex handlers can be rewritten in Go/Rust without changing the routing
- Capabilities are a declarative set of scripts, not dynamic routing logic
- Auth middleware lives in the fcgi wrapper, handlers assume pre-validated requests

### Need Types

| Type | Provider | What It Does |
|------|----------|--------------|
| `oidc` | forge | Register OIDC client in pocket-id |
| `ssl` | forge | Issue wildcard cert (or per-service cert) |
| `git` | forge | Issue git credentials (deploy tokens) |
| `proxy` | beacon | Configure public reverse proxy |

SSL is currently "forge does ACME, scps to all hosts." Future state: hosts request their cert from forge like any other need.

## Summary

| Component | What It Does |
|-----------|--------------|
| **Agent (all hosts)** | CGI handlers behind nginx vhost |
| **Base endpoints** | `/status`, `/manifest`, `/holdings` |
| **Provider endpoints** | `/oidc/*`, `/ssl/*`, `/git/*`, `/proxy/*` |
| **Fulfillment script** | Requests unfulfilled needs on activation |
| **GC sweep** | Providers delete resources no one claims |

The model:
- Hosts are responsible for themselves
- Providers serve, they don't orchestrate
- Holdings contract enables distributed GC
- RBAC is declarative, computed from Nix
- Auth uses existing SSH keys

No coordinator. No pub/sub. No scanning. Just HTTP calls between hosts that already know about each other.
