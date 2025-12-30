# Fort Control Plane Design

Technical design for a unified runtime coordination layer.

## Motivation

Current state has multiple mechanisms doing similar credential/config delivery:
- `service-registry` - OIDC registration, credential delivery, DNS updates (Ruby, SSH-based)
- `certificate-broker` - SSL cert generation and distribution
- `forgejo-bootstrap` - Git credential delivery
- `attic` bootstrap - Cache token delivery
- Various one-shot systemd services for runtime reconciliation

All rely on forge having root SSH access to all hosts, which is:
- A security concern (master key grants full access)
- Fragile (SSH timeouts, connection ordering)
- Push-based (forge must know about and reach all clients)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  Build time (Nix)                                       │
│  - exposedServices, aspects, roles declarations         │
│  - Output: /var/lib/fort/host-manifest.json             │
└─────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│  Agent (runs on each host)                              │
│  - Exposes host-manifest.json                           │
│  - Accepts credential writes                            │
│  - Provides sync capabilities (restart, journal, etc.)  │
│  - Authenticates callers via tailnet identity           │
└─────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│  Providers (forge, beacon, etc.)                        │
│  - Poll agents for manifests                            │
│  - Derive fulfillment needs from declarations           │
│  - Reconcile: create credentials, configure proxies     │
│  - Deliver via agent RPC                                │
└─────────────────────────────────────────────────────────┘
```

## Core Concepts

### Declaration Layer (Nix - already exists)

Services declare their needs via `fortCluster.exposedServices`:

```nix
fortCluster.exposedServices = [{
  name = "outline";
  port = 4654;
  visibility = "public";      # needs: beacon reverse proxy
  sso = {
    mode = "oidc";            # needs: OIDC client registration + credentials
    restart = "outline.service";
  };
}];
# implicitly needs: SSL cert delivery (any exposed service)
```

The declaration is the contract. Providers derive what needs to happen.

### Host Manifest (generated at build time)

Each host gets `/var/lib/fort/host-manifest.json` containing:
- `exposedServices` - services and their requirements
- `apps` - installed apps
- `aspects` - enabled aspects
- `roles` - assigned roles

Agents expose this to providers. This is the source of truth for "what does this host need?"

### Agents

Lightweight daemon on each host. Two types of operations:

**Async Needs** (provider-initiated):
- Credential delivery - provider writes to `/var/lib/fort-auth/{service}/`
- SSL delivery - provider writes to `/var/lib/fort/ssl/`
- Service signal - provider requests restart/reload after delivery

**Sync Capabilities** (caller-initiated):
- `journal:read` - stream journald logs for a service
- `status:query` - return system status, failed units
- `file:read` - read specific paths (scoped)
- `service:signal` - restart/reload a service

Agents validate all operations against:
1. Caller identity (via tailnet peer identity)
2. RBAC rules (does this principal have this capability?)
3. Manifest (can't restart a service that doesn't exist here)

### Providers

Each provider owns a domain of fulfillment:

| Provider | Fulfills |
|----------|----------|
| forge | OIDC registration, credential delivery, SSL certs, git tokens |
| beacon | Public reverse proxy configuration |
| (future) | Headscale host registration |

Providers run reconciliation loops:

```
every 60s:
  for host in known_hosts:
    manifest = GET host:agent/manifest
    for need in derive_needs(manifest):
      if not fulfilled(host, need):
        fulfill(host, need)
```

Fulfillment is idempotent. "Already exists" is success, not error.

## Data Flow Example

Ursula boots with a new service needing OIDC + public exposure:

```
1. Ursula boots
   └─ Agent starts, exposes manifest at :agent/manifest

2. Forge reconciler (next poll cycle)
   ├─ GET ursula:agent/manifest
   ├─ Sees: service "wiki" needs sso.mode=oidc
   ├─ Checks: /var/lib/fort-auth/wiki/client-id exists? No
   ├─ Registers OIDC client in pocket-id
   ├─ POST ursula:agent/credentials/wiki {client-id, client-secret}
   └─ POST ursula:agent/signal/wiki.service (restart)

3. Forge SSL reconciler (same or next cycle)
   ├─ Sees: ursula has exposed services
   ├─ Checks: SSL cert delivered? No
   └─ POST ursula:agent/credentials/ssl {fullchain, key}

4. Beacon reconciler (next poll cycle)
   ├─ GET ursula:agent/manifest
   ├─ Sees: service "wiki" has visibility=public
   ├─ Checks: nginx upstream configured? No
   └─ Adds upstream, reloads nginx
```

## RBAC Model

### Principals

Principals are identities that can make RPC calls. Currently defined in cluster manifest:

```nix
principals = {
  admin = { publicKey = "ssh-ed25519 ..."; roles = ["root" "secrets"]; };
  forge = { publicKey = "ssh-ed25519 ..."; roles = ["credential-provider"]; };
  ratched = { publicKey = "age1..."; roles = ["dev-sandbox" "secrets"]; };
};
```

### Capability Mapping

Roles map to agent capabilities:

| Role | Capabilities |
|------|--------------|
| `credential-provider` | `credentials:write`, `service:signal` |
| `dev-sandbox` | `journal:read`, `status:query`, `file:read` |
| `root` | all |

### Authentication

**Open question:** How do we authenticate RPC callers?

Options:
1. **Tailnet identity** - Caller is a tailscale peer, we know their hostname
2. **SSH key signing** - Reuse existing SSH keys to sign requests
3. **mTLS** - Agent requires client cert, maps cert to principal
4. **Bearer token** - Distribute tokens to principals (another credential to manage)

Tailnet identity gives us the *host*, but principals are *keys* not hosts. A host could have multiple principals (e.g., ratched has both the dev-sandbox key and CI keys).

**Pragmatic approach:** Use SSH keys to sign RPC requests. We already have the infrastructure - principals have keys, hosts have authorized keys. Agent validates signature against known principal keys.

```
Request:
  POST /signal/outline.service
  X-Principal: ratched
  X-Signature: <ssh-signature of request body>

Agent:
  1. Look up ratched's public key
  2. Verify signature
  3. Check ratched's roles → capabilities
  4. Execute if permitted
```

### RBAC Delivery

For now: RBAC rules baked into agent at build time from cluster manifest.

Future consideration: Runtime RBAC updates via gitops (agents poll repo) or dedicated delivery. Deferred - the declarative baseline is sufficient initially.

## Agent Implementation

Intentionally simple. Candidates:
- **Go** - Single static binary, easy to package in Nix, boring and reliable
- **Rust** - Same benefits, slightly harder to build
- **Elixir** - Overkill for a dumb agent, save for provider if needed

The agent is NOT the smart part. It's a secure RPC endpoint that validates and executes.

```
Endpoints:
  GET  /manifest              → return host-manifest.json
  GET  /status                → return system status
  POST /credentials/{type}/{service}  → write credentials, return ok
  POST /signal/{service}      → restart/reload service
  GET  /journal/{service}     → stream journald logs (SSE or websocket)
  GET  /file?path=...         → read file (scoped to allowed paths)
```

## Migration Path

1. **Build agent** - Simple Go binary, package in Nix
2. **Add agent aspect** - Deploy to all hosts (like host-status)
3. **Build forge provider** - Reconciler for OIDC, SSL, git credentials
4. **Run in parallel** - Both old (SSH) and new (agent) mechanisms
5. **Validate** - Ensure new path works for all credential types
6. **Cut over** - Disable SSH-based delivery
7. **Remove deployer SSH key** - Forge no longer needs root everywhere
8. **Build beacon provider** - Public proxy reconciliation
9. **Consolidate** - Remove service-registry, certificate-broker aspects

## Open Questions

1. **Agent discovery** - Providers iterate known hosts from manifest, or agents register on boot?
2. **Health checking** - How do providers know an agent is healthy vs just slow?
3. **Credential rotation** - How do we handle secret rotation? Providers re-deliver, agents restart?
4. **Multi-cluster** - Does this design extend if we ever have multiple clusters?
5. **Audit logging** - Where do RPC calls get logged? Agent-side, provider-side, both?

## Non-Goals (for now)

- **Event-driven pubsub** - Polling is simpler and the reliability model is clearer
- **Distributed coordination** - Single provider per domain is fine at our scale
- **Runtime RBAC updates** - Declarative baseline is sufficient initially
