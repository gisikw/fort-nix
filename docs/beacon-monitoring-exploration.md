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
| Polling-based discovery | Must | Beacon polls hosts; no push infrastructure needed |
| No mandatory agents | Must | HTTP probes; hosts just serve static JSON |
| VPN-only access | Phase 1 | Public access with split-gatekeeper auth is future work |
| Push notifications | Nice | Email, ntfy, Slack, etc. |
| Lightweight | Must | "What's going on" not "why is it down" |

## Recommendation: Gatus with Polling Discovery

### Why Polling (Not Push)

We considered runtime orchestration (hosts push "monitor me" needs to beacon), but polling is simpler here because:

1. **Polling is literally the point** - we're checking if things are up
2. **Hosts already expose status** - `<host>.fort.<domain>/status.json` exists
3. **Failure handling is natural** - if a host is unreachable, we keep existing data
4. **No coordination needed** - new hosts appear on tailnet, beacon discovers them

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Beacon (raishan)                         │
│                                                                  │
│  systemd timer (5min)              activation script (deploy)   │
│       │                                   │                      │
│       ▼                                   ▼                      │
│  ┌─────────────────┐              ┌─────────────────┐           │
│  │ tailscale status│              │ GC: remove hosts│           │
│  │ → fetch status  │              │ not in Nix list │           │
│  │ → merge config  │              │                 │           │
│  └────────┬────────┘              └────────┬────────┘           │
│           │                                │                     │
│           ▼                                ▼                     │
│       ┌─────────────────────────────────────────┐               │
│       │           config.yaml                    │               │
│       │  (Gatus auto-reloads ~30s)              │               │
│       └─────────────────────────────────────────┘               │
│                          │                                       │
│                          ▼                                       │
│                   ┌─────────────┐                               │
│                   │   Gatus     │                               │
│                   └─────────────┘                               │
└─────────────────────────────────────────────────────────────────┘
```

### Two-Phase Config Management

| Phase | Trigger | Operation | Trust Source |
|-------|---------|-----------|--------------|
| **Poll** | 5min timer | Add/update entries | Tailnet peers + status.json |
| **GC** | Beacon deploy | Remove orphan entries | Nix host list (canonical) |

**Poll phase** (additive):
- `tailscale status --json` → get peers matching `*.fort.<domain>`
- For each peer, fetch `status.json`
- If fetch succeeds, update/add entries
- If fetch fails, keep existing entries (preserve data during outages)
- Never removes entries

**GC phase** (subtractive):
- Runs on beacon deploy (activation script)
- Nix provides canonical list of hosts at build time
- Remove any config entries for hosts not in the Nix list
- This handles host decommissioning

### Extending status.json

Each host already serves `<host>.fort.<domain>/status.json`. Extend it with a `services` key:

```json
{
  "hostname": "q",
  "uptime": 123456,
  "failed_units": 0,
  "deploy": {
    "sha": "abc123",
    "timestamp": "2026-01-13T10:00:00Z"
  },
  "services": [
    {
      "name": "outline",
      "subdomain": "docs",
      "health": {
        "endpoint": "/api/health",
        "interval": "2m",
        "conditions": ["[STATUS] == 200", "[BODY].status == ok"]
      }
    },
    {
      "name": "forgejo",
      "subdomain": "git"
    }
  ]
}
```

Services without explicit `health` get defaults:
- `endpoint`: `/`
- `interval`: `5m`
- `conditions`: `["[STATUS] == 200", "[RESPONSE_TIME] < 5000"]`

### Service Health Declaration (Nix side)

Extend `fort.cluster.services` with optional health definitions:

```nix
fort.cluster.services = [{
  name = "outline";
  port = 3000;
  sso.mode = "oidc";

  # Optional health check definition
  health = {
    endpoint = "/api/health";
    interval = "2m";
    conditions = [
      "[STATUS] == 200"
      "[RESPONSE_TIME] < 2000"
      "[BODY].status == ok"
    ];
  };
}];
```

This gets serialized into `status.json` at build time.

To disable monitoring for a service:
```nix
health.enabled = false;
```

### Implementation Sketch

```nix
# apps/gatus/default.nix
{ subdomain ? "status", rootManifest, cluster, ... }:
{ config, pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  dataDir = "/var/lib/gatus";

  # Canonical host list from Nix (for GC)
  hostDirs = builtins.attrNames (builtins.readDir cluster.hostsDir);
  canonicalHosts = builtins.toJSON hostDirs;

  # Polling script - runs on timer, additive only
  pollScript = pkgs.writeShellScript "gatus-poll" ''
    set -euo pipefail

    DOMAIN="${domain}"
    CONFIG="${dataDir}/config.yaml"
    CACHE="${dataDir}/hosts"

    mkdir -p "$CACHE"

    # Get tailnet peers
    peers=$(${pkgs.tailscale}/bin/tailscale status --json | \
      ${pkgs.jq}/bin/jq -r '.Peer[] | select(.DNSName | test("^\\w+\\.fort\\.")) | .DNSName | sub("\\.fort\\..*"; "")')

    for host in $peers; do
      url="https://$host.fort.$DOMAIN/status.json"
      cache_file="$CACHE/$host.json"

      # Fetch status.json, keep existing on failure
      if ${pkgs.curl}/bin/curl -sf --max-time 10 "$url" -o "$cache_file.new"; then
        mv "$cache_file.new" "$cache_file"
      else
        rm -f "$cache_file.new"
        # Keep existing cache file if present
      fi
    done

    # Regenerate Gatus config from cached data
    ${pkgs.python3}/bin/python3 ${./generate-config.py} \
      --cache-dir "$CACHE" \
      --output "$CONFIG" \
      --domain "$DOMAIN"
  '';

  # GC script - runs on deploy, removes orphans
  gcScript = pkgs.writeShellScript "gatus-gc" ''
    set -euo pipefail

    CACHE="${dataDir}/hosts"
    CANONICAL='${canonicalHosts}'

    mkdir -p "$CACHE"

    # Remove cache files for hosts not in canonical list
    for cache_file in "$CACHE"/*.json; do
      [ -f "$cache_file" ] || continue
      host=$(basename "$cache_file" .json)
      if ! echo "$CANONICAL" | ${pkgs.jq}/bin/jq -e --arg h "$host" 'index($h)' >/dev/null; then
        echo "GC: removing $host (not in canonical host list)"
        rm -f "$cache_file"
      fi
    done
  '';
in
{
  services.gatus = {
    enable = true;
    configFile = "${dataDir}/config.yaml";
  };

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 root root -"
    "d ${dataDir}/hosts 0755 root root -"
  ];

  # Bootstrap empty config
  system.activationScripts.gatusBootstrap = ''
    if [ ! -f ${dataDir}/config.yaml ]; then
      echo 'web: {port: 8080}' > ${dataDir}/config.yaml
      echo 'endpoints: []' >> ${dataDir}/config.yaml
    fi
  '';

  # GC on deploy
  system.activationScripts.gatusGC = ''
    ${gcScript}
  '';

  # Polling timer
  systemd.timers.gatus-poll = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };

  systemd.services.gatus-poll = {
    description = "Poll hosts for Gatus monitoring config";
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pollScript;
    };
  };

  fort.cluster.services = [{
    name = "status";
    subdomain = subdomain;
    port = 8080;
    visibility = "vpn";
    sso.mode = "none";
    health.enabled = false;  # Don't monitor the monitor
  }];
}
```

### What This Monitors

| Source | What Gets Monitored |
|--------|---------------------|
| Host status.json | Host reachability, failed units, deploy status |
| services[].health | Per-service health checks with custom conditions |
| Defaults | Services without explicit health get basic 200 check |

**Addressing open tickets:**

| Ticket | Solution |
|--------|----------|
| fort-1nj (Headscale health) | Headscale app declares health in fort.cluster.services |
| fort-576 (Failed systemd) | Host status.json includes failed_units count |
| fort-e2w.8 (Backup alerts) | Backup service exposes status, declares health |
| fort-w38 (Stale images) | Could add image version info to status.json |

### Phase 1 Scope

- VPN-only access (`visibility = "vpn"`)
- Polling discovery from tailnet peers
- Per-service health checks from status.json
- GC on beacon deploy
- ntfy alerting (if deployed)

### Future Work

| Ticket | Description |
|--------|-------------|
| fort-ok4 | Split-gatekeeper: network-aware auth bypass |
| fort-r65 | Migrate Gatus to split-gatekeeper (depends on fort-ok4) |

### Alerting Configuration

Gatus supports 40+ alerting providers. Example with ntfy:

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

## Why Gatus

| Feature | Gatus | Uptime Kuma |
|---------|-------|-------------|
| Config approach | YAML file, auto-reloads | Socket.IO API |
| NixOS module | Yes | No |
| Fits polling model | Yes (file-based) | Awkward (API calls) |
| Community | ~9.5k stars | ~81k stars |

Gatus's file-based config with auto-reload is perfect for the polling + GC model.

## Next Steps

1. Add `health` option to `fort.cluster.services` schema in common/fort.nix
2. Extend status.json generation to include services
3. Create `apps/gatus/default.nix` with poll + GC scripts
4. Add to beacon role
5. Configure ntfy alerting
6. Optional: Homepage Gatus widget

## References

- [Gatus Documentation](https://gatus.io/docs)
- [Gatus Conditions](https://gatus.io/docs/conditions) - `[STATUS]`, `[BODY]`, `[RESPONSE_TIME]`
- [Gatus Config Reload](https://github.com/TwiN/gatus/issues/1064) - auto-reloads ~30s
- [NixOS Gatus Module](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/monitoring/gatus.nix)
