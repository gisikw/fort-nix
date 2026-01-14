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

    # Get infrastructure hosts by filtering to peers owned by "fort" user
    # Personal devices are registered under personal accounts, infra hosts under "fort"
    peers=$(${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null | \
      ${pkgs.jq}/bin/jq -r '
        .User as $users |
        ($users | to_entries[] | select(.value.LoginName == "fort") | .key) as $fort_uid |
        .Peer | to_entries[] | select(.value.UserID == ($fort_uid | tonumber)) | .value.HostName
      ' || echo "")

    # Always include self (not in peer list)
    LOCAL_HOST=$(${pkgs.hostname}/bin/hostname)
    peers="$LOCAL_HOST $peers"

    if [ -z "$peers" ]; then
      echo "No fort hosts found on tailnet"
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

    # Process each cached host file and build endpoints using jq
    # This avoids shell word-splitting issues with complex JSON
    endpoints=$(
      for cache_file in "$CACHE"/*.json; do
        [ -f "$cache_file" ] || continue
        host=$(basename "$cache_file" .json)

        # Extract host endpoint and service endpoints in one jq call
        ${pkgs.jq}/bin/jq \
          --arg host "$host" \
          --arg domain "$DOMAIN" \
          '
          # Host-level endpoint
          [{
            name: ("host: " + $host),
            group: "hosts",
            url: ("https://" + $host + ".fort." + $domain + "/status.json"),
            interval: "5m",
            conditions: ["[STATUS] == 200", "[RESPONSE_TIME] < 5000"]
          }] +
          # Service-level endpoints
          [.services // [] | .[] | select(.health.enabled != false) | {
            name: .name,
            group: $host,
            url: ("https://" + (.subdomain // .name) + "." + $domain + (.health.endpoint // "/")),
            interval: (.health.interval // "5m"),
            conditions: (.health.conditions // ["[STATUS] == 200", "[RESPONSE_TIME] < 5000"])
          }]
          ' "$cache_file"
      done | ${pkgs.jq}/bin/jq -s 'add // []'
    )

    # Write final config
    ${pkgs.jq}/bin/jq -n \
      --argjson endpoints "$endpoints" \
      '{
        storage: {
          type: "sqlite",
          path: "${dataDir}/data.db"
        },
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
