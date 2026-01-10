# Control Plane Implementation Plan

Audit of current state vs. `docs/control-plane-interfaces.md` spec, with implementation roadmap.

## Current State Inventory

### Working Infrastructure

**Control Plane Core:**
- `fort-provider` (`pkgs/fort-provider/`) - Go FastCGI, handles auth + RBAC + dispatch
- `fort` (`pkgs/fort/`) - bash CLI, SSH signing + request
- Nix module (`common/fort-agent.nix`) - `fort.host.needs`, `fort.host.capabilities`
- nginx integration - `/agent/*` location with VPN-only access

**Target Naming Convention:**
- `/fort/*` - path prefix for all control plane endpoints
- `fort` - CLI client (`fort <host> <capability> [request]`, request defaults to `{}`)
- `fort-consumer` - consumer-side service (requests needs, receives callbacks)
- `fort-provider` - provider-side FastCGI dispatch
- `fort-provider-*` - provider-side services (rotation, GC, etc.)

**RPC Capabilities (callable, all working):**
| Capability | Host | Description |
|------------|------|-------------|
| status | all | Return host status JSON |
| manifest | all | Return host manifest + capabilities |
| needs | all | Return list of declared needs (for GC) - **to be added** |
| journal | all | Fetch journalctl output (debug, restricted) |
| restart | all | Restart systemd unit (debug, restricted) |
| deploy | all | Trigger manual deployment confirmation (some hosts auto-deploy) |
| git-token | forgejo | Generate Forgejo deploy tokens |
| ssl-cert | certificate-broker | Return ACME certs (defined but unused) |

Note: `holdings` endpoint exists but is superseded by `needs` for GC purposes.

**End-to-End Working (needs → fulfill → capability):**
| Need | Consumer | Provider | Status |
|------|----------|----------|--------|
| git-token.default | gitops hosts | drhorrible | **Working** - RO token for comin |
| git-token.dev | dev-sandbox hosts | drhorrible | **Working** - RW token for push |

**Defined But Not Consumed:**
| Capability | Provider | Notes |
|------------|----------|-------|
| ssl-cert | drhorrible | Handler exists, returns wildcard certs only, no consumers |

**Legacy Mechanisms Still Active:**
| Mechanism | What It Does | Location |
|-----------|--------------|----------|
| acme-sync | rsync certs to all hosts | `aspects/certificate-broker/` |
| attic-key-sync | SSH push cache config + tokens | `apps/attic/` |
| service-registry | Multi-purpose sync: DNS records, beacon nginx, OIDC clients | `aspects/service-registry/` |

Note: `service-registry` does a lot:
- Collects host manifests from all hosts
- Pushes DNS records to headscale (extra-records.json) and coredns
- Generates nginx configs for public services on beacon
- Creates/deletes OIDC clients in pocket-id based on exposed services

**Consumer Service (`fort-fulfill`, target: `fort-consumer`):**
- `fort-fulfill.service` runs at activation
- `fort-fulfill-retry` timer (5m interval)
- Stores responses at `store` path
- Transforms via optional `transform` script
- Restarts/reloads specified services
- Supports identity override for principal auth

### What's NOT Implemented

**Consumer Side:**
1. Callback handlers - spec calls for `handler` script invoked on callback, current impl uses `store` + `restart`
2. Callback endpoints - no `/agent/needs/<type>/<id>` route (will become `/fort/needs/...`)
3. Needs enumeration - no `POST /agent/needs` endpoint (will become `/fort/needs`)
4. Nag-based retry - current impl just retries on timer, doesn't track `satisfied` state
5. Consumer state file - no `/var/lib/fort/consumer-state.json`

**Provider Side:**
1. Async handler mode - all handlers are RPC (single request → single response)
2. Provider orchestration - no aggregate invocation, no callback dispatch
3. `cacheResponse` option - not implemented
4. `triggers` option - no initialize/systemd trigger support
5. Provider state file - no `/var/lib/fort/provider-state.json`
6. GC sweep - no periodic check of consumer holdings

**Wire Protocol:**
1. Callback POST - provider → consumer not implemented
2. HTTP 202 for async - all responses are synchronous 200

## Gap Analysis

### Spec vs. Implementation Schema Differences

**Need Options:**
| Spec | Current | Migration |
|------|---------|-----------|
| `from` (single host) | `providers` (list) | Change to `from` |
| `request` | `request` | Keep |
| `nag` (duration) | - | Add (default 15m) |
| `handler` (script) | `store` + `transform` + `restart` | Replace with `handler` |
| - | `reload` | Remove |
| - | `identity` | Remove (handle in handler) |

**Capability Options:**
| Spec | Current | Migration |
|------|---------|-----------|
| `handler` | `handler` | Keep |
| `allowed` | `allowed` | Keep |
| `mode = "rpc"` | (implicit all) | Add (default async) |
| `cacheResponse` | - | Add |
| `triggers.initialize` | - | Add |
| `triggers.systemd` | - | Add |
| - | `needsGC` | Remove (inferred from mode) |
| - | `ttl` | Remove |
| - | `satisfies` | Keep for docs |
| - | `description` | Keep for docs |

### Architectural Decisions (Resolved)

1. **Use `from` (single provider), not `providers` list**
   - Multi-provider creates GC complexity - which provider owns what?
   - Single provider keeps reconciliation simple
   - Migrate current `providers` to `from`

2. **Callback handlers replace store+restart entirely**
   - No legacy support needed - we're early enough in migration
   - Simple cases (file + restart) just write a simple handler script
   - Keeps the model uniform

3. **Handler model: RPC vs. Aggregate**
   - RPC: dumb passthrough, single request → single response
   - Async: aggregate all requests, handler reconciles with underlying resources
   - Default is async, explicit `mode = "rpc"` for operational endpoints

4. **`needsGC` goes away**
   - Inferred from absence of `mode = "rpc"`
   - All async capabilities need GC, RPC capabilities don't

5. **`/fort/holdings` superseded by `/fort/needs`**
   - GC uses needs enumeration, not holdings
   - Remove holdings from mandatory endpoints

## Implementation Phases

### Phase 1: Naming and Path Alignment

Rename existing components to target naming convention.

**1.1 Rename packages** ✓
- `pkgs/fort-agent-wrapper/` → `pkgs/fort-provider/` ✓
- `pkgs/fort-agent-call/` → `pkgs/fort/` ✓
- CLI request arg already optional (defaults to `{}`) ✓

**1.2 Rename Nix module**
- `common/fort-agent.nix` → `common/fort.nix` (or merge into existing)

**1.3 Rename paths**
- `/agent/*` → `/fort/*` (nginx location)
- `/etc/fort-agent/` → `/etc/fort/`
- `/var/lib/fort-agent/` → `/var/lib/fort/` (consolidate)

**1.4 Rename services**
- `fort-fulfill.service` → `fort-consumer.service`
- `fort-fulfill-retry.timer` → `fort-consumer-retry.timer`

**1.5 Update AGENTS.md**
- Document new `fort` CLI usage
- Update `fort` CLI references ✓

Files: `pkgs/`, `common/`, nginx configs, AGENTS.md

### Phase 2: Consumer Callback Infrastructure

Add callback support to receive provider-initiated updates.

**2.1 Add callback endpoint to fort-provider**
- Route: `POST /fort/needs/<type>/<id>`
- Auth: verify caller matches declared `from` provider
- Dispatch: invoke need handler with payload on stdin
- Update: set `satisfied = true` in consumer state

**2.2 Add needs enumeration endpoint**
- Route: `POST /fort/needs`
- Response: `{"needs": ["type/id", ...]}`
- Source: build-time generated list (same source as needs.json, but static)
- No runtime file dependency - just a static response compiled into config

**2.3 Add consumer state tracking**
- File: `/var/lib/fort/consumer-state.json`
- Schema: `{need_id → {satisfied: bool, last_sought: timestamp}}`
- Update fort-consumer to:
  - Check `satisfied` before requesting
  - Track `last_sought` timestamp
  - Implement nag-based retry (only request if unsatisfied AND past nag interval)

**2.4 Simplify need options**
- Replace `store`/`transform`/`restart`/`reload` with single `handler` option
- Add `nag` option (duration, default 15m)
- Change `providers` to `from` (single provider)
- Remove `identity` (handle in handler if needed)

Files: `common/fort.nix`, `pkgs/fort-provider/`

### Phase 3: Provider Orchestration

Add async capability mode with aggregate handlers.

**3.1 Update capability options**
- `mode = "rpc"` for synchronous (default is async)
- `cacheResponse` - persist responses for handler to reuse
- `triggers.initialize` - run on boot
- `triggers.systemd` - list of units that trigger re-run (fires after unit succeeds)
- Remove `needsGC` and `ttl` (inferred from mode)

**3.2 Add provider state management**
- File: `/var/lib/fort/provider-state.json`
- Schema: `{capability → {origin:need → {request, response?, updated_at}}}`
- Load state on boot, persist after handler runs

**3.3 Implement async handler invocation**
- On new request: add to state, invoke handler with ALL requests, update responses
- On trigger: invoke handler, compare responses, callback if changed
- Handler input: `{origin:need → {request, response}}`
- Handler output: `{origin:need → response}`

**3.4 Implement callback dispatch**
- After handler returns, POST responses to consumer callback endpoints
- Fire-and-forget (ignore response status)
- Return 202 to original request

**3.5 Add boot-time initialization**
- If `triggers.initialize`, run handler on service start
- Load persisted state, invoke handler, dispatch callbacks

**3.6 Add systemd triggers**
- For each `triggers.systemd` unit, create path/timer watcher
- On trigger: re-invoke handler, diff responses, callback changes

Files: `common/fort.nix`, `pkgs/fort-provider/`, new `fort-provider-*` services

### Phase 4: GC Implementation

Implement garbage collection for orphaned state.

**4.1 Add GC sweep timer (`fort-provider-gc`)**
- Periodic service (e.g., 1h interval)
- For each async capability:
  - For each origin in provider state
  - Call `POST /fort/needs` on origin
  - If need not in response (and host reachable): remove from state
  - Invoke handler with updated state (for cleanup)

**4.2 Positive-absence rules**
- Only delete on 200 + absence
- Network failures = assume still in use
- Host removed from cluster = immediate cleanup

Files: `common/fort.nix`, `fort-provider-gc` service

### Phase 5: Migration

Move existing services from legacy delivery to control plane.

**5.1 Git tokens (first - already partially working)**
- Current: working via old need schema (`providers`, `store`, `transform`)
- Target: new schema (`from`, `handler`)
- Migrate gitops + dev-sandbox needs to new format
- Validates the new consumer infrastructure before tackling new capabilities

**5.2 SSL certificates**
- Current: rsync-based acme-sync timer (push model)
- Target: ssl-cert capability + consumer needs (pull model with callbacks)
- Capability handler already exists (wildcard only), needs consumer declarations
- Add `fort.host.needs.ssl-cert.default` to hosts that need certs
- Convert handler to async mode with `triggers.systemd = ["acme-${domain}.service"]`
- Remove acme-sync once callbacks working

**5.3 Attic cache tokens**
- Current: attic-key-sync SSH push timer
- Target: attic-token capability + consumer needs
- Needs new capability handler on attic host
- Consumers declare `fort.host.needs.attic-token.default`

**5.4 OIDC registration**
- Current: service-registry creates/deletes pocket-id clients based on exposed services
- Target: oidc-register capability with aggregate handler
- Consumers declare `fort.host.needs.oidc.servicename`
- Provider creates client in pocket-id, callbacks credentials
- This is the canonical aggregate capability example

**5.5 Proxy configuration**
- Current: service-registry generates nginx vhost configs and pushes to beacon
- Target: proxy-configure capability
- Consumer declares `fort.host.needs.proxy.servicename`
- Beacon creates vhost, callbacks confirmation
- GC removes vhosts when need disappears

**5.6 Remove legacy mechanisms**
- acme-sync timer (replaced by ssl-cert callbacks)
- attic-key-sync timer (replaced by attic-token capability)
- service-registry aspect - decomposed into:
  - DNS: could remain centralized or move to control plane
  - OIDC: replaced by oidc-register capability
  - Proxy: replaced by proxy-configure capability

## Spec Ambiguities (Resolved)

1. **Handler vs. Store semantics** → Handlers for all
   - All callbacks invoke handler script
   - Simple cases write a simple handler

2. **Provider-side handler contract** → Handlers receive all
   - Async handlers receive all requests, return all responses
   - RPC handlers receive single request, return single response

3. **RPC vs. Async mode** → Default async, explicit `mode = "rpc"`
   - Operational endpoints (journal, restart, status) use RPC
   - Credential/resource capabilities use async

4. **Trigger timing** → After unit succeeds
   - `triggers.systemd` fires after unit succeeds
   - Can't use PathModified - don't know paths ahead of time (arbitrary domains)
   - Idempotent handlers make extra runs harmless

5. **Default nag interval** → 15 minutes
   - Unless specified otherwise, needs nag every 15m when unsatisfied

## Dependencies

```
Phase 1 (naming) ←─ all subsequent phases
Phase 2.1 (callback endpoint) ←─ Phase 3.4 (callback dispatch)
Phase 2.2 (needs enum) ←─ Phase 4.1 (GC sweep)
Phase 2.3 (consumer state) ←─ Phase 2.1 (callback endpoint)
Phase 3.2 (provider state) ←─ Phase 3.3 (async invocation)
Phase 3.3 (async invocation) ←─ Phase 3.4 (callback dispatch)
Phase 3.* ←─ Phase 5.* (migrations)
Phase 4.* ←─ Phase 5.* (can do migrations before GC, but GC needed for cleanup)
```

Suggested order: 1.* → 2.* → 3.* → 4.* → 5.*

## Estimated Scope

| Phase | Effort | Risk |
|-------|--------|------|
| 1 (naming) | Small | Low - mechanical renames |
| 2 (consumer) | Medium | Low - extend existing infrastructure |
| 3 (provider) | Large | Medium - new orchestration model |
| 4 (GC) | Medium | Medium - correctness matters |
| 5 (migration) | Variable | Medium - per-service work |

Phase 1 is mechanical cleanup. Phase 2 extends what exists.
Phase 3 is the major architectural addition. Phase 4 ensures long-term health.
Phase 5 is the payoff.
