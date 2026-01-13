# Beacon Monitoring: Lightweight Status Monitoring Exploration

## Problem Statement

We have several open tickets related to monitoring and alerting:

| Ticket | Priority | Description |
|--------|----------|-------------|
| fort-1nj | P2 | Add monitoring for headscale/mesh health |
| fort-576 | P2 | Add alerting for failed systemd services across cluster |
| fort-e2w.8 | P2 | Create backup failure alerts |
| fort-w38 | P3 | Track and alert on stale container image versions |

The existing Grafana/Prometheus stack on fort-observability is powerful but overwhelming for simple "what's going on" questions. We want something lightweight on the beacon (raishan) that can:

- Know when the home cluster is down (beacon is a VPS, independent of home infrastructure)
- Answer "what's up" without deep-diving into metrics
- Eventually send notifications when things go wrong

## Requirements

| Requirement | Priority | Notes |
|-------------|----------|-------|
| Runtime-driven config | Must | Services announce themselves; beacon discovers what to monitor |
| No mandatory agents | Must | HTTP/TCP probes primary; agents optional for richer data |
| VPN-only access | Phase 1 | Public access with split-gatekeeper auth is future work |
| Push notifications | Nice | Email, ntfy, Slack, etc. |
| Lightweight | Must | "What's going on" not "why is it down" |

### Key Insight: Runtime Orchestration

The fort-nix pattern is **runtime orchestration on top of declarative infrastructure**. Hosts don't rebuild beacon when they deploy - they announce needs and beacon fulfills them:

```
Host deploys → announces "monitor me" need → beacon provider fulfills → Gatus config updates
```

This matches existing patterns: DNS registration, OIDC client registration, etc. Monitoring is just another need/capability pair.

## Candidates Evaluated

### 1. Gatus (Recommended)

**Repository:** [TwiN/gatus](https://github.com/TwiN/gatus)

A developer-oriented status page with health checks, alerting, and incident management.

![Gatus Dashboard](https://raw.githubusercontent.com/TwiN/gatus/master/.github/assets/dashboard-conditions.jpg)

**Pros:**
- YAML-based configuration
- **Auto-reloads config file** (~30s) - perfect for runtime updates
- No agents required - HTTP/TCP/DNS/ICMP/SSH probes
- In nixpkgs with NixOS module (`services.gatus`)
- Lightweight single binary (Go)
- 40+ alerting integrations (ntfy, email, Slack, Discord, etc.)
- Rich condition expressions: `[STATUS]`, `[BODY]`, `[RESPONSE_TIME]`
- SSH endpoints can execute commands on remote hosts

**Cons:**
- Smaller community than Uptime Kuma (~9.5k stars vs ~81k)
- No web UI for config changes (feature, not bug, for us)

**Runtime config pattern:**
```
Provider aggregates needs → writes /var/lib/gatus/config.yaml → Gatus auto-reloads
```

---

### 2. Uptime Kuma

**Repository:** [louislam/uptime-kuma](https://github.com/louislam/uptime-kuma)

![Uptime Kuma Light Mode](https://uptime.kuma.pet/img/light.jpg)

**Pros:**
- Beautiful UI, huge community
- Has [Python API wrapper](https://pypi.org/project/uptime-kuma-api/) for programmatic control

**Cons:**
- API is Socket.IO based (more complex than file writes)
- UI-centric design doesn't fit our runtime orchestration model as cleanly
- No NixOS module

**Verdict:** Viable, but Gatus's file-based config reload is simpler for our pattern.

---

### 3. Beszel

**Disqualified:** Requires agents on all monitored hosts.

---

### 4. Homepage

**Verdict:** Complementary. Could add a Gatus widget to display status on the dashboard. Not a replacement.

---

## Recommendation: Gatus with Runtime Orchestration

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Beacon (raishan)                         │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────┐ │
│  │ monitoring      │    │ config.yaml     │    │   Gatus     │ │
│  │ capability      │───▶│ (generated)     │───▶│  (watches)  │ │
│  │ handler         │    │                 │    │             │ │
│  └─────────────────┘    └─────────────────┘    └─────────────┘ │
└─────────────────────────────────────────────────────────────────┘
           ▲                                            │
           │ needs                                      │ probes
           │                                            ▼
┌──────────┴──────────┐                    ┌───────────────────────┐
│   Hosts (q, joker,  │                    │  Services             │
│   drhorrible, etc)  │                    │  - /status endpoints  │
│                     │                    │  - health checks      │
│   fort.cluster      │                    │  - port availability  │
│   .services[].health│                    └───────────────────────┘
└─────────────────────┘
```

### Service Health Declaration

Extend `fort.cluster.services` with optional health definitions:

```nix
# In an app's default.nix
fort.cluster.services = [{
  name = "outline";
  port = 3000;
  sso.mode = "oidc";

  # NEW: Health check definition (optional)
  health = {
    # Override endpoint (default: "/")
    endpoint = "/api/health";

    # Override interval (default: "5m")
    interval = "2m";

    # Override conditions (default: ["[STATUS] == 200" "[RESPONSE_TIME] < 5000"])
    conditions = [
      "[STATUS] == 200"
      "[RESPONSE_TIME] < 2000"
      "[BODY].status == ok"
    ];
  };
}];
```

**Defaults when `health` is omitted:**
- Endpoint: `https://<subdomain>.<domain>/`
- Interval: `5m`
- Conditions: `["[STATUS] == 200" "[RESPONSE_TIME] < 5000"]`

**To disable monitoring for a service:**
```nix
health.enabled = false;
```

### Host-Level Monitoring

Every host with `observable` aspect gets a base health check against `<host>.fort.<domain>/status` (the fort-agent endpoint). This provides:
- Host reachability
- Failed systemd units count
- Deploy status

The monitoring provider on beacon automatically includes these - no per-host configuration needed.

### Implementation Sketch

```nix
# apps/gatus/default.nix
{ subdomain ? "status", rootManifest, ... }:
{ config, pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  dataDir = "/var/lib/gatus";

  # Handler receives aggregated monitoring needs from all hosts
  monitoringHandler = pkgs.writeShellScript "handler-monitoring" ''
    set -euo pipefail
    input=$(cat)

    # Transform needs into Gatus endpoint config
    endpoints=$(echo "$input" | ${pkgs.jq}/bin/jq -c '
      to_entries | map(
        .value.request as $req |
        {
          name: $req.name,
          url: $req.url,
          interval: ($req.interval // "5m"),
          conditions: ($req.conditions // ["[STATUS] == 200"])
        }
      )
    ')

    # Write Gatus config
    ${pkgs.jq}/bin/jq -n \
      --argjson endpoints "$endpoints" \
      '{
        web: { port: 8080 },
        endpoints: $endpoints
      }' > ${dataDir}/config.yaml

    # Gatus auto-reloads within ~30s

    # Return success for all requesters
    echo "$input" | ${pkgs.jq}/bin/jq 'to_entries | map({key: .key, value: {registered: true}}) | from_entries'
  '';
in
{
  services.gatus = {
    enable = true;
    configFile = "${dataDir}/config.yaml";
  };

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 root root -"
  ];

  # Bootstrap config so Gatus starts
  system.activationScripts.gatusBootstrap = ''
    if [ ! -f ${dataDir}/config.yaml ]; then
      echo '{"web": {"port": 8080}, "endpoints": []}' > ${dataDir}/config.yaml
    fi
  '';

  fort.cluster.services = [{
    name = "status";
    subdomain = subdomain;
    port = 8080;
    visibility = "vpn";  # VPN-only for now
    sso.mode = "none";
  }];

  fort.host.capabilities.monitoring = {
    handler = monitoringHandler;
    mode = "async";
    description = "Register services for uptime monitoring";
  };
}
```

### What This Monitors (addressing open tickets)

| Ticket | Solution |
|--------|----------|
| fort-1nj (Headscale health) | Automatic - headscale app declares health endpoint |
| fort-576 (Failed systemd) | Automatic - all observable hosts checked via /status |
| fort-e2w.8 (Backup alerts) | Backup service exposes health endpoint, declares in fort.cluster.services |
| fort-w38 (Stale images) | Could expose reconciliation status as health endpoint |

### Phase 1 Scope

- VPN-only access (`visibility = "vpn"`)
- Basic HTTP health checks
- Host /status endpoint monitoring
- ntfy alerting (if ntfy is deployed)

### Future Work

| Ticket | Description |
|--------|-------------|
| fort-ok4 | Split-gatekeeper: network-aware auth bypass |
| fort-r65 | Migrate Gatus to split-gatekeeper (depends on fort-ok4) |

Once split-gatekeeper exists, Gatus can be exposed publicly with OIDC for external access while remaining auth-free on VPN.

### Alerting Configuration

Gatus supports 40+ alerting providers. Initial setup with ntfy:

```yaml
alerting:
  ntfy:
    url: "https://ntfy.gisi.network"
    topic: "monitoring"
    default-alert:
      enabled: true
      failure-threshold: 3
      success-threshold: 2
```

Or email via SMTP, Slack webhooks, Discord, PagerDuty, etc.

## Next Steps

1. Define `lib.types.health` option schema in common/fort.nix
2. Create `apps/gatus/default.nix` with monitoring capability
3. Add to beacon role
4. Update existing apps to declare health (or rely on defaults)
5. Configure ntfy alerting
6. Optional: Homepage widget for dashboard view

## References

- [Gatus Documentation](https://gatus.io/docs)
- [Gatus Conditions](https://gatus.io/docs/conditions)
- [Gatus Config Reload](https://github.com/TwiN/gatus/issues/1064)
- [NixOS Gatus Module](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/monitoring/gatus.nix)
- [Uptime Kuma API](https://github.com/lucasheld/uptime-kuma-api)
