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

---

# Appendix: Alternative Universes

Three idealized solutions from different engineering traditions, presented for entertainment and/or future regret.

---

## A. The Erlang Telephony Astronaut

*"Five nines, but make it beautiful."*

This engineer worked on telecom switches in the 90s, believes Joe Armstrong was a prophet, and thinks the BEAM VM is the closest humanity has come to solving distributed systems.

### Architecture

Every host runs an Elixir node. They form a fully-connected mesh over tailnet (distributed Erlang natively supports this). State is replicated via CRDTs - specifically, an OR-Set for cluster membership and LWW-Registers for credential state.

```
┌─────────────────────────────────────────────────────────────────┐
│                    CRDT State Layer                             │
│  δ-CRDTs gossip between nodes, merge automatically              │
│  No coordination, no consensus, eventual consistency by math    │
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────────┐
│                   Capability Tokens                             │
│  Biscuit-style macaroons, signed capability chains              │
│  Attenuatable: delegate subsets of your authority               │
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────────┐
│                   Policy as Datalog                             │
│  Authorization rules are logic programs                         │
│  "can(X, write, Y) :- role(X, provider), needs(Y, credential)"  │
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────────┐
│                   OTP Supervision                               │
│  Let it crash. Supervisor restarts. State survives in CRDT.     │
│  Hot code reload for zero-downtime capability updates.          │
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────────┐
│                   Merkle DAG Audit Log                          │
│  Every operation is hash-linked. Tamper-evident history.        │
│  Fork detection is O(1). "Show me divergence" is a query.       │
└─────────────────────────────────────────────────────────────────┘
```

### Key Properties

- **No polling** - State changes propagate via CRDT delta gossip
- **No leader** - Every node is equivalent, forge is just "a node that happens to talk to pocket-id"
- **Capabilities not roles** - You don't "have permission," you "hold an unforgeable token that IS the permission"
- **Policy is queryable** - "Who can write to ursula?" is a Datalog query, not archaeology
- **Audit is structural** - The history is a hash-linked DAG, not a log file

### Why It's Overkill

CRDT libraries are PhD theses. Capability systems require rethinking every auth assumption. You'd spend 6 months building infrastructure to manage 8 hosts.

### Why It's Beautiful

The failure modes are *mathematically impossible* rather than "mitigated by retry logic." When it works, it works by proof, not by prayer.

### Tech Stack

- Elixir/OTP on every node
- Lasp or DeltaCRDT for state
- Biscuit for capability tokens
- Datalog (via `exlog` or embedded Prolog)
- Custom merkle DAG (or piggyback on something like Prolly trees)

---

## B. The Kubernetes Cost Center

*"We should be able to kubectl apply our way to happiness."*

This engineer has mass battle scars from production k8s, believes GitOps is a lifestyle, and hasn't met a problem that couldn't be solved with another operator. The CTO has forgotten they exist, so budget is infinite.

### Architecture

Stand up a lightweight k8s cluster (k3s, because we're not *animals*). Every coordination concern becomes a Custom Resource Definition. Operators watch resources and reconcile. ArgoCD syncs desired state from git. Vault manages secrets. Linkerd provides mTLS. It's YAML all the way down.

```yaml
# cluster-state/credentials/ursula-outline-oidc.yaml
apiVersion: fort.nix/v1alpha1
kind: OIDCCredential
metadata:
  name: outline
  namespace: ursula
spec:
  service: outline
  provider: pocket-id
  restart: outline.service
status:
  provisioned: true
  clientId: "..."
  lastRotation: "2025-01-15T..."
```

```
┌─────────────────────────────────────────────────────────────────┐
│                        GitOps Layer                             │
│  ArgoCD watches repo, syncs CRs to cluster                      │
│  Desired state IS the git history                               │
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────────┐
│                    Operator Framework                           │
│  OIDCCredentialOperator, SSLCertOperator, ProxyConfigOperator   │
│  Each watches its CRD, reconciles actual → desired              │
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────────┐
│                      Vault + ESO                                │
│  External Secrets Operator syncs Vault → k8s Secrets            │
│  Rotation is Vault's problem now                                │
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────────┐
│                    Service Mesh (Linkerd)                       │
│  mTLS everywhere, identity from SPIFFE/SPIRE                    │
│  "Authorization policy" is just more YAML                       │
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────────┐
│                   Observability Stack                           │
│  Prometheus, Grafana, Loki, Tempo                               │
│  "What happened" is a query, not SSH + grep                     │
└─────────────────────────────────────────────────────────────────┘
```

### The Operators

```go
// oidc_credential_controller.go
func (r *OIDCCredentialReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    var cred fortv1.OIDCCredential
    if err := r.Get(ctx, req.NamespacedName, &cred); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // Check if credentials exist on target host
    exists, err := r.AgentClient.CredentialsExist(cred.Namespace, cred.Spec.Service)
    if err != nil {
        return ctrl.Result{RequeueAfter: time.Minute}, err
    }

    if !exists {
        // Register with pocket-id, deliver to agent
        clientCreds, _ := r.PocketID.RegisterClient(cred.Spec.Service)
        r.AgentClient.WriteCredentials(cred.Namespace, cred.Spec.Service, clientCreds)
        r.AgentClient.RestartService(cred.Namespace, cred.Spec.Restart)
    }

    // Update status
    cred.Status.Provisioned = true
    r.Status().Update(ctx, &cred)

    return ctrl.Result{RequeueAfter: time.Hour}, nil  // Re-check for rotation
}
```

### Key Properties

- **GitOps native** - The repo IS the desired state, ArgoCD enforces it
- **CRDs as schema** - Type-safe(ish) YAML with validation
- **Operators are just controllers** - Same pattern as our Model A, but in k8s idiom
- **Vault handles secrets lifecycle** - Rotation, access control, audit - Vault's problem
- **Mesh handles identity** - SPIFFE gives workload identity, mTLS everywhere

### Why It's Overkill

You're running an entire k8s cluster (etcd, API server, controllers, CNI, CSI, service mesh, vault, argocd...) to manage 8 NixOS hosts. The k8s cluster has more moving parts than the infrastructure it manages.

### Why It's Tempting

The ecosystem is *there*. Need secret rotation? Vault has it. Need policy? OPA/Gatekeeper. Need observability? Prometheus. Need GitOps? ArgoCD. You're assembling legos, not machining parts.

### Tech Stack

- k3s (lightweight k8s)
- ArgoCD for GitOps
- Vault + External Secrets Operator
- Linkerd for service mesh
- Custom operators in Go (kubebuilder)
- Prometheus + Grafana + Loki

### Sample Day-2 Operation

```bash
# Add new service needing OIDC
cat <<EOF | kubectl apply -f -
apiVersion: fort.nix/v1alpha1
kind: OIDCCredential
metadata:
  name: wiki
  namespace: ursula
spec:
  service: wiki
  provider: pocket-id
  restart: wiki.service
EOF

# Operator reconciles, credentials appear on ursula
# Git commit happens automatically via ArgoCD write-back
# Grafana alert confirms provisioning latency was 3.2s
```

---

## C. The P2P Anarchist

*"Why does forge have special powers? That's hierarchy. Hierarchy is a single point of failure. Also, DNS is why we can't have nice things."*

This engineer ran a BitTorrent tracker in college, is still mad about SecondLife's centralized asset servers, contributed to Scuttlebutt, and believes the correct response to "how do nodes discover each other" is "Kademlia DHT, obviously." They've been waiting for the semantic web since 2001.

### Architecture

There is no forge. There is no beacon. There are only **peers**. Every node is equivalent. Discovery happens via DHT. Credentials are content-addressed and distributed via a gossip protocol. Identity is a public key. Trust is a web, not a tree.

```
┌─────────────────────────────────────────────────────────────────┐
│                     Kademlia DHT                                │
│  Every node participates. No special discovery servers.         │
│  "Who provides OIDC?" → DHT lookup → set of capable peers       │
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────────┐
│               Content-Addressed Credentials                     │
│  Credentials are IPLD objects. Immutable. Hash-linked.          │
│  "Give me credential X" = "Give me content at hash X"           │
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────────┐
│                   Gossip Protocol                               │
│  Needs propagate via epidemic broadcast                         │
│  Fulfillments propagate the same way                            │
│  No polling - information diffuses through the network          │
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────────┐
│                    Web of Trust                                 │
│  No central CA. Peers sign each other's keys.                   │
│  Trust is transitive with attenuation.                          │
│  "I trust alice, alice trusts bob" → I kinda trust bob          │
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────────┐
│               Capability Delegation                             │
│  Any peer can delegate capabilities to any other peer           │
│  No one "grants" permissions - you attenuate and pass on        │
│  The network IS the authorization layer                         │
└─────────────────────────────────────────────────────────────────┘
```

### How It Works

**Discovery:**
```
ursula publishes to DHT:
  key: hash("needs:oidc:outline")
  value: {peer_id: ursula, service: outline, timestamp: ...}

any peer providing OIDC capability is subscribed to "needs:oidc:*"
  → receives notification via DHT pub/sub
  → fulfills if it can
  → publishes fulfillment to DHT
```

**Credential Distribution:**
```
credential = {client_id: "...", client_secret: "...", for: "outline@ursula"}
cid = ipfs.add(credential)  # Content-addressed

fulfillment published to DHT:
  key: hash("fulfilled:oidc:outline@ursula")
  value: {cid: cid, provider: drhorrible, sig: ...}

ursula subscribes to "fulfilled:*:*@ursula"
  → receives fulfillment
  → fetches content by CID (from any peer that has it!)
  → verifies provider signature against web of trust
  → applies credential
```

**Web of Trust:**
```
# Bootstrap: cluster root key signs initial peer keys
root_key.sign(drhorrible_key, capabilities: [:oidc_provider, :ssl_provider])
root_key.sign(raishan_key, capabilities: [:proxy_provider])
root_key.sign(ursula_key, capabilities: [:service_host])

# Peers can delegate:
drhorrible_key.sign(ci_key, capabilities: [:oidc_provider],
                    constraint: {services: ["forgejo-*"]})

# Verification is a chain walk:
#   ci_key → signed by drhorrible → signed by root → trusted
#   with accumulated constraints checked at each hop
```

### The Manifesto

> "You call it 'forge' and 'beacon' but what you mean is 'master' and 'gatekeeper.'
> Why does one machine decide who gets credentials? Why does one machine control external access?
>
> In a true peer network, any node that CAN provide OIDC registration SHOULD be able to.
> Any node that has external connectivity SHOULD be able to offer ingress.
> The network routes around damage - including architectural damage.
>
> DNS gave us a hierarchical namespace controlled by ICANN and domain registrars.
> We replaced it with a flat namespace where names are public keys.
> Tailscale is a step in the right direction - identity is key-based, the mesh is flat.
> Now extend that philosophy to the application layer.
>
> Content-addressing solves cache invalidation, distribution, and integrity in one primitive.
> The DHT solves discovery without servers.
> Web of trust solves identity without certificate authorities.
>
> The only hierarchy should be the transitive delegation of capabilities,
> and that hierarchy is *chosen* by each peer, not imposed by architecture."

### Key Properties

- **No special nodes** - "Forge" is just a peer that happens to have pocket-id credentials
- **Location-independent** - Credentials identified by content hash, fetchable from anywhere
- **Partition-tolerant** - Network splits? Each partition continues operating with available providers
- **Censorship-resistant** - No single node can refuse service to another (okay, maybe less relevant for a homelab)
- **Emergent coordination** - Order arises from local rules, not global orchestration

### Why It's Overkill

You're building a decentralized autonomous organization to manage 8 computers in your house that you own. The web of trust has 8 nodes. The DHT has 8 nodes. The "partition tolerance" protects against... your router rebooting.

### Why It's Philosophically Appealing

The architecture has no lies in it. There IS no master. There IS no center. It's not "master with extra steps" - it's genuinely flat. If you believe architectures encode values, this one encodes the right ones.

Also if you ever wanted to make your homelab a template that others could federate with... it's already designed for that. Your ursula could request credentials from my forge. We're all just peers.

### Tech Stack

- libp2p (the networking stack under IPFS)
- Kademlia DHT for discovery
- IPLD for content-addressed data
- Gossipsub for pub/sub
- UCAN or Biscuit for capability tokens
- Custom web-of-trust implementation (or adapt Keybase's)

### Sample Interaction

```
# ursula needs OIDC for new service
$ fort-peer publish-need --type oidc --service wiki

# propagates via gossip, any capable peer can fulfill
# on drhorrible (or any OIDC-capable peer):
[fort-peer] Received need: oidc for wiki@ursula
[fort-peer] I have oidc_provider capability, fulfilling...
[fort-peer] Registered client with pocket-id
[fort-peer] Published credential to network: QmXyz...
[fort-peer] Announced fulfillment to DHT

# back on ursula:
[fort-peer] Received fulfillment for wiki from drhorrible
[fort-peer] Fetching credential QmXyz... (found 2 peers with content)
[fort-peer] Verifying signature chain: drhorrible → root ✓
[fort-peer] Applying credential, restarting wiki.service
```

---

## Comparison Matrix

| Aspect | Erlang Telephony | Kubernetes | P2P Anarchist |
|--------|------------------|------------|---------------|
| State model | CRDTs | etcd + CRDs | DHT + content-addressing |
| Coordination | None (convergent) | Controllers | Gossip |
| Identity | Capability tokens | SPIFFE/mTLS | Public keys + web of trust |
| Discovery | Distributed Erlang | DNS/service mesh | Kademlia DHT |
| Policy | Datalog | OPA/Rego YAML | Capability chains |
| Failure mode | "Crash and restart" | "Retry with backoff" | "Route around damage" |
| Philosophy | Mathematical elegance | Enterprise pragmatism | Radical decentralization |
| Overkill factor | 10x | 15x | 50x |
| Mass nerd appeal | Very high | Medium | Astronomical |

---

## Which One Should We Build?

None of them. We should build Model A from the main document.

But if the CTO forgets we're a cost center, it's Option B.
If we're doing it for the love of the craft, it's Option A.
If we want to prefigure the post-capitalist internet, it's Option C.

Or we could just keep using SSH. It works. It's fine. It's *fine*.
