{ subdomain ? "status", rootManifest, cluster, ... }:
{ config, pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  dataDir = "/var/lib/gatus";

  # Canonical host list from Nix (for GC)
  hostDirs = builtins.attrNames (builtins.readDir cluster.hostsDir);
  canonicalHosts = builtins.toJSON hostDirs;

  # Polling script - runs on timer, fetches status.json from tailnet peers
  pollScript = pkgs.writeShellScript "gatus-poll" ''
    set -euo pipefail

    DOMAIN="${domain}"
    CONFIG="${dataDir}/config.yaml"
    CACHE="${dataDir}/hosts"

    mkdir -p "$CACHE"

    # Get tailnet peers that match *.fort.<domain>
    peers=$(${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null | \
      ${pkgs.jq}/bin/jq -r '.Peer // {} | to_entries[] | select(.value.DNSName | test("^[a-z0-9-]+\\.fort\\.")) | .value.DNSName | sub("\\.fort\\..*"; "")' || echo "")

    if [ -z "$peers" ]; then
      echo "No tailnet peers found, skipping poll"
      exit 0
    fi

    for host in $peers; do
      url="https://$host.fort.$DOMAIN/status.json"
      cache_file="$CACHE/$host.json"

      # Fetch status.json, keep existing on failure (preserve during outages)
      if ${pkgs.curl}/bin/curl -sf --max-time 10 "$url" -o "$cache_file.new" 2>/dev/null; then
        mv "$cache_file.new" "$cache_file"
        echo "Updated $host"
      else
        rm -f "$cache_file.new"
        echo "Failed to fetch $host, keeping existing cache"
      fi
    done

    # Regenerate Gatus config from cached data
    ${generateConfigScript}
  '';

  # Config generation script - builds Gatus YAML from cached host data
  generateConfigScript = pkgs.writeShellScript "gatus-generate-config" ''
    set -euo pipefail

    DOMAIN="${domain}"
    CONFIG="${dataDir}/config.yaml"
    CACHE="${dataDir}/hosts"

    # Start building endpoints array
    endpoints="[]"

    # Process each cached host
    for cache_file in "$CACHE"/*.json; do
      [ -f "$cache_file" ] || continue

      host=$(basename "$cache_file" .json)
      data=$(cat "$cache_file")

      # Add host-level health check (always)
      host_endpoint=$(${pkgs.jq}/bin/jq -n \
        --arg name "$host" \
        --arg url "https://$host.fort.$DOMAIN/status.json" \
        '{
          name: ("host: " + $name),
          group: "hosts",
          url: $url,
          interval: "5m",
          conditions: ["[STATUS] == 200", "[RESPONSE_TIME] < 5000"]
        }')
      endpoints=$(echo "$endpoints" | ${pkgs.jq}/bin/jq --argjson ep "$host_endpoint" '. + [$ep]')

      # Add service-level health checks
      services=$(echo "$data" | ${pkgs.jq}/bin/jq -c '.services // []')
      for svc in $(echo "$services" | ${pkgs.jq}/bin/jq -c '.[]'); do
        enabled=$(echo "$svc" | ${pkgs.jq}/bin/jq -r '.health.enabled // true')
        [ "$enabled" = "false" ] && continue

        name=$(echo "$svc" | ${pkgs.jq}/bin/jq -r '.name')
        subdomain=$(echo "$svc" | ${pkgs.jq}/bin/jq -r '.subdomain // .name')
        endpoint_path=$(echo "$svc" | ${pkgs.jq}/bin/jq -r '.health.endpoint // "/"')
        interval=$(echo "$svc" | ${pkgs.jq}/bin/jq -r '.health.interval // "5m"')
        conditions=$(echo "$svc" | ${pkgs.jq}/bin/jq -c '.health.conditions // ["[STATUS] == 200", "[RESPONSE_TIME] < 5000"]')

        svc_endpoint=$(${pkgs.jq}/bin/jq -n \
          --arg name "$name" \
          --arg group "$host" \
          --arg url "https://$subdomain.$DOMAIN$endpoint_path" \
          --arg interval "$interval" \
          --argjson conditions "$conditions" \
          '{
            name: $name,
            group: $group,
            url: $url,
            interval: $interval,
            conditions: $conditions
          }')
        endpoints=$(echo "$endpoints" | ${pkgs.jq}/bin/jq --argjson ep "$svc_endpoint" '. + [$ep]')
      done
    done

    # Write final config
    ${pkgs.jq}/bin/jq -n \
      --argjson endpoints "$endpoints" \
      '{
        web: { port: 8080 },
        endpoints: $endpoints
      }' | ${pkgs.yj}/bin/yj -jy > "$CONFIG.tmp"

    mv "$CONFIG.tmp" "$CONFIG"
    echo "Generated Gatus config with $(echo "$endpoints" | ${pkgs.jq}/bin/jq 'length') endpoints"
  '';

  # GC script - runs on deploy, removes hosts not in canonical Nix list
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

    # Regenerate config after GC
    ${generateConfigScript}
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

  # Bootstrap empty config so Gatus can start
  system.activationScripts.gatusBootstrap = ''
    if [ ! -f ${dataDir}/config.yaml ]; then
      mkdir -p ${dataDir}
      cat > ${dataDir}/config.yaml << 'EOF'
web:
  port: 8080
endpoints: []
EOF
    fi
  '';

  # GC on deploy - remove orphan hosts
  system.activationScripts.gatusGC = {
    text = ''
      ${gcScript}
    '';
    deps = [ "gatusBootstrap" ];
  };

  # Polling timer - fetch status.json from peers every 5 minutes
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
    name = "gatus";
    subdomain = subdomain;
    port = 8080;
    visibility = "vpn";
    sso.mode = "none";
    health.enabled = false;  # Don't monitor the monitor
  }];
}
