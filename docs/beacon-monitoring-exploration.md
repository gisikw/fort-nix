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
| No agents on monitored hosts | Must | Probes only (HTTP, TCP, ping, DNS) |
| Declarative config | Must | YAML or Nix-native, not click-ops |
| OIDC support OR disable auth | Must | No double-auth with oauth2-proxy |
| Push notifications | Nice | Email, ntfy, Slack, etc. |
| Lightweight | Must | "What's going on" not "why is it down" |

## Candidates Evaluated

### 1. Gatus

**Repository:** [TwiN/gatus](https://github.com/TwiN/gatus)

A developer-oriented status page with health checks, alerting, and incident management.

![Gatus Dashboard](https://raw.githubusercontent.com/TwiN/gatus/master/.github/assets/dashboard-conditions.jpg)

**Pros:**
- YAML-based configuration (fully declarative)
- **Native OIDC support** - can use Pocket ID directly
- No agents required - HTTP/TCP/DNS/ping probes
- In nixpkgs with NixOS module (`services.gatus`)
- Lightweight single binary
- 40+ alerting integrations (ntfy, email, Slack, Discord, PagerDuty, etc.)
- Status page built-in
- Supports condition expressions (response time < 500ms, status == 200, etc.)

**Cons:**
- Smaller community than Uptime Kuma (~9.5k stars vs ~81k)
- No web UI for config changes (YAML only)

**Auth options:**
```yaml
security:
  oidc:
    issuer-url: "https://id.gisi.network"
    client-id: "gatus"
    client-secret: "${OIDC_CLIENT_SECRET}"
    redirect-url: "https://status.gisi.network/authorization-code/callback"
    scopes: ["openid", "profile", "email"]
```

**NixOS module:**
```nix
services.gatus = {
  enable = true;
  settings = {
    endpoints = [
      { name = "Headscale"; url = "https://hs.gisi.network/health"; }
    ];
  };
};
```

---

### 2. Uptime Kuma

**Repository:** [louislam/uptime-kuma](https://github.com/louislam/uptime-kuma)

A fancy self-hosted monitoring tool with a beautiful UI.

![Uptime Kuma Light Mode](https://uptime.kuma.pet/img/light.jpg)

![Uptime Kuma Status Page](https://user-images.githubusercontent.com/1336778/134628766-a3fe0981-0926-4285-ab46-891a21c3e4cb.png)

**Pros:**
- Beautiful, polished UI
- Huge community (~81k stars)
- 90+ notification integrations
- Status pages with custom CSS
- WebSocket-based real-time updates

**Cons:**
- **No native OIDC** - would need oauth2-proxy (double auth)
- **UI-only configuration** - not declarative without hacks
- Requires Node.js runtime
- No NixOS module (would need to run as container or custom service)

**Auth situation:**
No native SSO. [Open feature request since 2022](https://github.com/louislam/uptime-kuma/issues/553). Would require oauth2-proxy in front, meaning two logins or header-passthrough complexity.

---

### 3. Beszel

**Repository:** [henrygd/beszel](https://github.com/henrygd/beszel)

A lightweight server monitoring platform with Docker stats.

**Disqualified:** Requires agents on all monitored hosts. Architecture is hub + agent model - the agent runs on each system to report metrics. This doesn't fit our "probes only" requirement.

---

### 4. Homepage (as monitoring dashboard)

**Repository:** [gethomepage/homepage](https://github.com/gethomepage/homepage)

Already deployed at home.gisi.network. Has widgets for Uptime Kuma and Gatus.

**Pros:**
- Already deployed
- Can display status from other tools via widgets
- Highly customizable

**Cons:**
- Not a monitoring tool - just displays data from other sources
- Would need another tool actually doing the monitoring
- No alerting capability

**Verdict:** Complementary, not a replacement. Could display Gatus status via widget.

---

### 5. Statping-ng / Kener

Briefly evaluated but:
- **Statping-ng**: Less active development, no clear OIDC story
- **Kener**: GitHub-based storage model, SvelteKit stack adds complexity

Neither offered clear advantages over Gatus for our requirements.

---

## Comparison Matrix

| Feature | Gatus | Uptime Kuma | Beszel | Homepage |
|---------|-------|-------------|--------|----------|
| Declarative config | YAML | UI only | N/A | YAML |
| Native OIDC | Yes | No | Yes | N/A |
| No agents needed | Yes | Yes | **No** | N/A |
| In nixpkgs | Yes | No | No | No |
| NixOS module | Yes | No | No | No |
| Alerting | 40+ | 90+ | Yes | No |
| Community size | ~9.5k | ~81k | ~5k | ~23k |

## Recommendation: Gatus

**Gatus is the clear winner** for our requirements:

1. **Declarative by design** - YAML config fits perfectly with NixOS patterns. We can generate the config from Nix and it becomes part of the system definition.

2. **Native OIDC** - Direct integration with Pocket ID. No oauth2-proxy needed, no double authentication, single sign-on just works.

3. **No agents** - Pure probe-based monitoring. HTTP health checks, TCP port checks, DNS resolution, ICMP ping. Perfect for "is it up" from an external vantage point.

4. **NixOS native** - `services.gatus` module exists. Clean integration path.

5. **Right-sized** - It's a status page with alerting, not a metrics platform. Answers "what's going on" without the complexity of Grafana dashboards.

### Proposed Implementation

```nix
# apps/gatus/default.nix (sketch)
{ subdomain ? "status", hostManifest, rootManifest, cluster, ... }:
{ config, pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;

  # Derive endpoints from cluster hosts
  hostDirs = builtins.attrNames (builtins.readDir cluster.hostsDir);
  # ... generate health check endpoints
in
{
  services.gatus = {
    enable = true;
    environmentFile = config.age.secrets.gatus-oidc.path;
    settings = {
      web.port = 8080;

      security.oidc = {
        issuer-url = "https://id.${domain}";
        client-id = "gatus";
        client-secret = "\${OIDC_CLIENT_SECRET}";
        redirect-url = "https://${subdomain}.${domain}/authorization-code/callback";
        scopes = [ "openid" "profile" "email" ];
      };

      endpoints = [
        {
          name = "Headscale";
          url = "https://hs.${domain}/health";
          interval = "5m";
          conditions = [ "[STATUS] == 200" ];
        }
        # ... more endpoints
      ];

      alerting = {
        ntfy = {
          url = "https://ntfy.${domain}";
          topic = "alerts";
        };
      };
    };
  };

  fort.cluster.services = [{
    name = "status";
    subdomain = subdomain;
    port = 8080;
    sso.mode = "none";  # Gatus handles its own OIDC
  }];
}
```

### What This Could Monitor (addressing open tickets)

| Ticket | How Gatus Helps |
|--------|-----------------|
| fort-1nj (Headscale health) | HTTP check on /health endpoint, alert on failure |
| fort-576 (Failed systemd) | HTTP check on fort-agent /status endpoint per host |
| fort-e2w.8 (Backup alerts) | Could expose backup status via simple HTTP endpoint |
| fort-w38 (Stale images) | Not directly - but could check a reconciliation endpoint |

### Next Steps

1. Create `apps/gatus/default.nix` with basic config
2. Register OIDC client with Pocket ID (oidc-register capability)
3. Add to beacon role or raishan manifest
4. Configure initial endpoints (headscale, forge, key services)
5. Set up ntfy or email alerting
6. Optionally add Homepage widget to display Gatus status

## References

- [Gatus Documentation](https://gatus.io/docs)
- [Gatus OIDC Configuration](https://twin.sh/articles/56/securing-gatus-with-oidc-using-auth0)
- [Authelia Gatus Integration](https://www.authelia.com/integration/openid-connect/clients/gatus/)
- [NixOS Gatus Module](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/monitoring/gatus.nix)
- [Uptime Kuma SSO Discussion](https://github.com/louislam/uptime-kuma/issues/553)
