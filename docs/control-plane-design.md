# Fort Control Plane Design

Technical design for unified runtime coordination.

## The Core Insight

In most distributed systems, you need coordination because nodes don't have perfect knowledge. Node A doesn't know Node B exists. Someone has to introduce them.

**We have perfect knowledge at eval time.** Nix knows:
- Every host in the cluster
- Every service on every host
- Every provider and its capabilities
- The full topology

So there's nothing to coordinate at runtime. The host already knows what it needs and where to get it. Just bake it in and let hosts fetch their own dependencies.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Eval Time (Nix)                         │
│                                                                 │
│  Host manifest includes:                                        │
│    - What services I run                                        │
│    - What each service needs (OIDC, SSL, public proxy, etc.)    │
│    - Where to get each thing (computed from cluster topology)   │
│                                                                 │
│  This is COMPUTED, not configured. Nix knows everything.        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ deployed to host
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Activation                              │
│                                                                 │
│  for each unfulfilled need:                                     │
│    request it from the provider (with backoff)                  │
│                                                                 │
│  Host is responsible for itself. No coordinator needed.         │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│  Forge (Server)  │ │ Beacon (Server)  │ │  Other Provider  │
│                  │ │                  │ │                  │
│  POST /oidc/...  │ │  POST /proxy/... │ │  POST /...       │
│  POST /ssl/...   │ │                  │ │                  │
│  POST /git/...   │ │                  │ │                  │
│                  │ │                  │ │                  │
│  Serves requests │ │  Serves requests │ │  Serves requests │
│  from hosts      │ │  from hosts      │ │  from hosts      │
└──────────────────┘ └──────────────────┘ └──────────────────┘
```

## The Model

**Providers are servers, not controllers.**

Forge isn't "orchestrating credential delivery." Forge runs an API:
```
POST /oidc/register { service: "outline", host: "ursula" }
  → { client_id: "...", client_secret: "..." }
```

Beacon isn't "scanning for public services." Beacon runs an API:
```
POST /proxy/configure { host: "ursula", service: "outline", port: 4654 }
  → { status: "configured" }
```

They're servers. They serve. Hosts request.

**Hosts are clients, not targets.**

Ursula doesn't wait to be provisioned. On activation:
1. Check what's needed (from manifest)
2. Check what's already fulfilled (files exist?)
3. Request anything missing (with backoff)
4. Done

**It's just `fetchurl` for credentials.**

```nix
# Nix derivation fetching source:
src = fetchurl { url = "https://..."; sha256 = "..."; };

# Host fetching credential (same pattern):
creds = fetchCredential { provider = forge; service = "outline"; };
```

Host knows what it needs. Host fetches it. Provider serves it.

## Manifest Shape

```nix
# Computed at eval time from exposedServices + cluster topology
{
  hostname = "ursula";

  exposedServices = [{
    name = "outline";
    port = 4654;
    sso.mode = "oidc";
    sso.restart = "outline.service";
    visibility = "public";
  }];

  # DERIVED from cluster config - host doesn't configure this
  providers = {
    oidc = "https://drhorrible.fort.gisi.network:agent";
    ssl = "https://drhorrible.fort.gisi.network:agent";
    publicProxy = "https://raishan.fort.gisi.network:agent";
  };
}
```

The host knows what it needs (from `exposedServices`) and where to get it (from `providers`). Both computed by Nix.

## Activation Flow

```bash
#!/usr/bin/env bash
# Runs on host activation

set -euo pipefail

fetch_with_backoff() {
  local url="$1"
  local output="$2"
  local attempt=1

  while [ $attempt -le 10 ]; do
    if curl -sf "$url" -o "$output"; then
      return 0
    fi
    echo "Attempt $attempt failed, retrying..."
    sleep $((2 ** attempt))
    attempt=$((attempt + 1))
  done

  echo "Failed to fetch $url after $attempt attempts"
  return 1
}

# For each service needing OIDC
for service in outline wiki; do
  cred_dir="/var/lib/fort-auth/$service"

  if [ ! -f "$cred_dir/client-id" ]; then
    echo "Fetching OIDC credentials for $service..."
    mkdir -p "$cred_dir"

    fetch_with_backoff \
      "$OIDC_PROVIDER/oidc/register?service=$service&host=$HOSTNAME" \
      "$cred_dir/credentials.json"

    # Parse response, write files, restart service
    jq -r '.client_id' "$cred_dir/credentials.json" > "$cred_dir/client-id"
    jq -r '.client_secret' "$cred_dir/credentials.json" > "$cred_dir/client-secret"
    systemctl restart "$service.service"
  fi
done

# For each service needing public proxy
for service in outline; do
  echo "Ensuring public proxy for $service..."
  fetch_with_backoff \
    "$PROXY_PROVIDER/proxy/ensure?host=$HOSTNAME&service=$service&port=4654" \
    /dev/null
done
```

## Provider Implementation

Providers expose simple HTTP APIs. Handlers are idempotent.

**OIDC Registration (on forge):**

```bash
#!/usr/bin/env bash
# /oidc/register handler

service="$QUERY_service"
host="$QUERY_host"
client_name="${service}.${host}"

# Check if already registered
existing=$(pocket-id-admin list-clients | grep "$client_name" || true)

if [ -n "$existing" ]; then
  # Return existing credentials
  pocket-id-admin get-client "$client_name" --format json
else
  # Register new client
  pocket-id-admin create-client "$client_name" --format json
fi
```

**Public Proxy (on beacon):**

```bash
#!/usr/bin/env bash
# /proxy/ensure handler

host="$QUERY_host"
service="$QUERY_service"
port="$QUERY_port"

upstream_file="/etc/nginx/upstreams.d/${host}-${service}.conf"

if [ ! -f "$upstream_file" ]; then
  cat > "$upstream_file" <<EOF
upstream ${host}_${service} {
  server ${host}.fort.gisi.network:${port};
}
EOF

  # Add server block...
  nginx -s reload
fi

echo '{"status": "configured"}'
```

## Failure Handling

**Provider down:** Host retries with exponential backoff. Eventually consistent.

**Activation doesn't block:** Fetch script runs in background. Services start with placeholder creds (like today), real creds arrive when provider responds.

**Deploys are retries:** Redeploy host = re-run activation = retry failed fetches.

**Provider comes back:** Next host activation (or redeploy) succeeds. No manual intervention.

## Credential Rotation

**Option A: Periodic refresh**
```nix
systemd.timers.refresh-credentials = {
  wantedBy = [ "timers.target" ];
  timerConfig.OnCalendar = "daily";
};

systemd.services.refresh-credentials = {
  script = ''
    # Re-fetch all credentials, providers return fresh ones
    ${activationScript}
  '';
};
```

**Option B: Redeploy**

Credential rotation = bump a version in manifest = deploy = hosts fetch new creds.

This is actually correct for GitOps: changes flow through the repo, not side-channels.

**Option C: Host exposes rotation endpoint**

If forge needs to *force* rotation:
```
POST ursula:agent/rotate?service=outline
```

But ursula *chooses* to expose this. The host is the authority on its affordances.

## RBAC

Providers need to validate requests. "Is this host allowed to request OIDC for this service?"

**Simple approach:** Provider checks the cluster manifest.
- Host requests: "I'm ursula, I need OIDC for outline"
- Provider checks: "Does ursula's manifest include outline with sso.mode=oidc?"
- If yes, fulfill. If no, reject.

The manifest is the authorization. It's signed (part of the Nix closure). Hosts can only request what they're configured to need.

**Authentication:** Requests come over tailnet. Tailscale identity = host identity. No additional auth needed.

## Agent API

Each host runs a simple agent that:
1. Exposes the manifest (`GET /manifest`)
2. Accepts credential writes (`POST /credentials/{service}`)
3. Provides capabilities (`GET /journal/{service}`, etc.)

But the agent is **reactive**, not **passive**. The host drives its own fulfillment. The agent is just the API for providers to respond through (and for optional capabilities like journal access).

```
Host Activation:
  POST forge/oidc/register?service=outline
    → forge validates, registers, responds with creds
  Host writes creds locally
  Host restarts service

vs. today's model:
  Host sits there
  Forge SSHes in, writes creds, restarts service
  Host is passive target
```

## Migration Path

1. **Add provider endpoints to forge** - `/oidc/register`, `/ssl/cert`, `/git/token`
2. **Add provider endpoints to beacon** - `/proxy/ensure`
3. **Add fetch script to host activation** - Requests what's needed
4. **Run in parallel** - Both old (SSH push) and new (host pull) work
5. **Validate** - Ensure all credential types work
6. **Remove SSH-based delivery** - service-registry, certificate-broker, etc.
7. **Remove forge's SSH key** - It's just a server now

## What We're Building

| Component | What It Does |
|-----------|--------------|
| **Provider API (forge)** | Serves OIDC, SSL, git credentials on request |
| **Provider API (beacon)** | Configures public proxies on request |
| **Activation script (hosts)** | Fetches unfulfilled needs with backoff |
| **Agent (hosts)** | Exposes capabilities (journal, status, etc.) |

That's it. No coordinator. No pub/sub. No polling. No scanning.

## Why This Works

**Perfect knowledge:** Nix computes the full topology. Hosts know everything at build time.

**Unidirectional flow:** State (manifest) flows from Nix. Requests flow from hosts to providers. No bidirectional bindings.

**Host autonomy:** Hosts are responsible for themselves. They request what they need. No one pushes to them without consent.

**Idempotent providers:** Request the same thing twice, get the same result. Safe to retry.

**Eventual consistency:** Provider down? Retry later. Deploy out of order? Everyone catches up.

## The Philosophy

> Fetching OIDC credentials is no different than fetching a tarball.
>
> The host knows what it needs (declared in Nix).
> The host knows where to get it (computed from cluster topology).
> The host fetches it (on activation, with backoff).
>
> Providers don't coordinate. They serve.
> Hosts don't wait to be provisioned. They request.
>
> There's no coordination layer because there's nothing to coordinate.
> The coordination happened at eval time. Runtime is just execution.

---

# Appendix: Alternative Universes

Four idealized solutions from different engineering traditions, presented for entertainment and/or future regret.

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

### Why It's Overkill

You're building a decentralized autonomous organization to manage 8 computers in your house that you own. The web of trust has 8 nodes. The DHT has 8 nodes. The "partition tolerance" protects against... your router rebooting.

### Why It's Philosophically Appealing

The architecture has no lies in it. There IS no master. There IS no center. It's not "master with extra steps" - it's genuinely flat. If you believe architectures encode values, this one encodes the right ones.

### Tech Stack

- libp2p (the networking stack under IPFS)
- Kademlia DHT for discovery
- IPLD for content-addressed data
- Gossipsub for pub/sub
- UCAN or Biscuit for capability tokens
- Custom web-of-trust implementation (or adapt Keybase's)

---

## D. The Store-Passing Purist

*"What if credentials were derivations?"*

This engineer read the Nix thesis in one sitting, believes `nixpkgs` is humanity's greatest collaborative achievement, and gets genuinely upset when people use `writeFile` instead of `writeTextFile`. They've replaced their todo list with a flake.

### Philosophy

The entire cluster state is a Nix expression. Credentials aren't "delivered" - they're *built*. Runtime agents are just binary caches serving content-addressed blobs. Mutable files are a lie.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Nix Expression Layer                         │
│  Cluster state IS a flake. Credentials ARE derivations.         │
│  clusterState.ursula.credentials.outline → /nix/store/xyz...    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ nix build
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Content-Addressed Store                      │
│  /nix/store/abc123-oidc-outline-ursula/client-id               │
│  Immutable. Reproducible (mostly). Auditable.                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ nix copy
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Agent as Binary Cache                        │
│  Agents don't "accept credentials" - they serve store paths     │
│  nix copy --to ssh://ursula /nix/store/abc123-oidc-...         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ activation script
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Symlink Farm                                 │
│  /var/lib/fort-auth/outline → /nix/store/abc123-oidc-.../      │
│  "Mutable" paths are just symlinks to immutable store paths     │
└─────────────────────────────────────────────────────────────────┘
```

### The Manifesto

> "You have `/var/lib/fort-auth/outline/client-secret`. What produced it? When? With what inputs? Can you rebuild it? Can you diff it against last week's version?
>
> You don't know. It's a file. Files lie.
>
> `/nix/store/abc123-oidc-outline-ursula` tells the truth. It was built by derivation `xyz`, with inputs `[pocket-id-url, service-name, ...]`, at time `T`. The hash proves integrity. The derivation proves provenance.
>
> 'But OIDC registration has side effects!' Yes. So does `fetchurl`. We handle it the same way: fixed-output derivations, content-addressing, and accepting that some things touch the network.
>
> 'But credentials rotate!' Yes. Rotation produces a new store path. The old one remains, immutable, for rollback. This isn't a bug, it's the entire point.
>
> Runtime coordination isn't 'delivering credentials.' It's ensuring the correct store paths are present on the correct hosts. `nix copy` is the delivery mechanism. The agent is a binary cache. The manifest is a flake.
>
> You're already doing this for packages. Why are credentials special?"

### Why It's Overkill

You're encoding your secrets in the Nix store, which is world-readable by default. You'd need `nix-store --add-fixed` and careful permission management. You're fighting the tool - Nix wasn't designed for secrets management.

Also, the impurity is real. OIDC registration can't be pure. You're either lying about it (FOD with unstable hashes) or doing the reconciliation dance anyway.

### Why It's Beautiful

The abstraction is honest. Instead of pretending credentials are "just files that get written," you're explicit: they're content-addressed artifacts with derivations that describe their provenance.

And rollback! If a credential rotation breaks something, `nix profile rollback` and you're back. No "restore from backup," no "hope you kept the old file." The previous store path is right there.

### Tech Stack

- Nix (obviously)
- Fixed-output derivations for impure builds
- `nix copy` for distribution
- Activation scripts for symlinking
- Maybe `agenix` or `sops-nix` for the encryption layer

---

## Comparison Matrix

| Aspect | Host-Driven (Main) | Erlang | Kubernetes | P2P | Store-Passing |
|--------|-------------------|--------|------------|-----|---------------|
| State model | Nix manifests | CRDTs | etcd + CRDs | DHT | Nix store |
| Who initiates | Host | N/A (converge) | Controller | Peers | Build system |
| Provider role | Server | Peer | Operator | Peer | Cache |
| Coordination | None (host knows) | None (convergent) | Controllers | Gossip | `nix copy` |
| Failure mode | Retry with backoff | Crash and restart | Retry with backoff | Route around | Build failed |
| Philosophy | Radical simplicity | Mathematical elegance | Enterprise pragmatism | Decentralization | Radical purity |
| Overkill factor | 1x | 10x | 15x | 50x | ∞ |

---

## Which One Should We Build?

**The main design (host-driven).** It's the only one that isn't cosplaying.

The host knows what it needs. The host fetches it. Providers serve. There's no coordination because Nix already did the coordination at eval time.

But if the CTO forgets we're a cost center, it's Option B.
If we're doing it for the love of the craft, it's Option A.
If we want to prefigure the post-capitalist internet, it's Option C.
If we want to disappear so far up our own abstractions that we achieve enlightenment, it's Option D.

Or we could just keep using SSH. It works. It's fine. It's *fine*.
