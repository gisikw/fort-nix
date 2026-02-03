{
  rootManifest,
  hostManifest,
  ...
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = rootManifest.fortConfig.settings.domain;
  hostname = hostManifest.hostName;
  statusDir = "/var/lib/fort/status";
  dropsDir = "/var/lib/fort/drops";
  cominStore = "/var/lib/comin/store.json";
  deployRsInfo = "/var/lib/fort/deploy-info.json";

  # Import the upload handler
  fortUpload = import ../../pkgs/fort-upload { inherit pkgs; };
  uploadSocket = "/run/fort/upload.sock";

  # Services with health monitoring info for Gatus
  servicesJson = builtins.toJSON (map (svc: {
    name = svc.name;
    subdomain = if svc.subdomain != null then svc.subdomain else svc.name;
    health = {
      enabled = svc.health.enabled;
      endpoint = svc.health.endpoint;
      interval = svc.health.interval;
      conditions = svc.health.conditions;
    };
  }) config.fort.cluster.services);

  statusScript = pkgs.writeShellScript "generate-host-status" ''
    set -euo pipefail

    # Uptime in seconds
    uptime_seconds=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)

    # System status via systemctl
    system_status=$(systemctl is-system-running 2>/dev/null || echo "unknown")

    # Failed units count
    failed_units=$(systemctl --failed --no-legend 2>/dev/null | wc -l || echo "0")

    # Deploy info - prefer comin (gitops), fall back to deploy-rs static file
    if [ -f "${cominStore}" ]; then
      # GitOps host - parse comin store
      deploy_info=$(${pkgs.jq}/bin/jq -r '
        .generations[0] // {} |
        {
          commit: (.selected_commit_msg // "unknown" | capture("release: (?<sha>[a-f0-9]+)") | .sha // "unknown"),
          timestamp: (.selected_commit_msg // "" | capture(" - (?<ts>.+)$") | .ts // null),
          branch: (.selected_branch_name // "unknown"),
          source: "comin"
        }
      ' "${cominStore}" 2>/dev/null || echo '{"commit":"unknown","branch":"unknown","source":"comin"}')
    elif [ -f "${deployRsInfo}" ]; then
      # Non-gitops host - use deploy-rs written file
      deploy_info=$(${pkgs.jq}/bin/jq -c '. + {source: "deploy-rs"}' "${deployRsInfo}" 2>/dev/null || echo '{"commit":"unknown","branch":"unknown","source":"deploy-rs"}')
    else
      deploy_info='{"commit":"unknown","branch":"unknown","source":"none"}'
    fi

    # Build the status JSON
    ${pkgs.jq}/bin/jq -n \
      --arg hostname "${hostname}" \
      --arg status "$system_status" \
      --argjson uptime "$uptime_seconds" \
      --argjson failed "$failed_units" \
      --argjson deploy "$deploy_info" \
      --argjson services '${servicesJson}' \
      --arg generated "$(date -Iseconds)" \
      '{
        hostname: $hostname,
        status: $status,
        uptime_seconds: $uptime,
        failed_units: $failed,
        deploy: $deploy,
        services: $services,
        generated_at: $generated
      }' > "${statusDir}/status.json.tmp"

    mv "${statusDir}/status.json.tmp" "${statusDir}/status.json"
  '';

  indexHtml = pkgs.writeText "index.html" ''
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>${hostname} - Fort Status</title>
      <style>
        :root { --bg: #1a1a2e; --card: #16213e; --accent: #0f3460; --text: #e4e4e4; --ok: #4ecca3; --warn: #ffc107; --err: #e74c3c; }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: system-ui, -apple-system, sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 1rem; }
        .card { background: var(--card); border-radius: 12px; padding: 2rem; max-width: 400px; width: 100%; box-shadow: 0 4px 24px rgba(0,0,0,0.3); }
        h1 { font-size: 1.5rem; margin-bottom: 1.5rem; display: flex; align-items: center; gap: 0.5rem; }
        .status-dot { width: 12px; height: 12px; border-radius: 50%; }
        .status-dot.running { background: var(--ok); box-shadow: 0 0 8px var(--ok); }
        .status-dot.degraded { background: var(--warn); box-shadow: 0 0 8px var(--warn); }
        .status-dot.failed, .status-dot.unknown { background: var(--err); box-shadow: 0 0 8px var(--err); }
        dl { display: grid; grid-template-columns: auto 1fr; gap: 0.75rem 1rem; }
        dt { color: #888; font-size: 0.85rem; }
        dd { font-family: monospace; font-size: 0.9rem; }
        .commit { color: var(--ok); }
        .footer { margin-top: 1.5rem; padding-top: 1rem; border-top: 1px solid var(--accent); font-size: 0.75rem; color: #666; }
        a { color: var(--ok); }
      </style>
    </head>
    <body>
      <div class="card">
        <h1><span class="status-dot" id="status-dot"></span> <span id="hostname">${hostname}</span></h1>
        <dl>
          <dt>Status</dt><dd id="status">loading...</dd>
          <dt>Uptime</dt><dd id="uptime">-</dd>
          <dt>Deploy</dt><dd id="deploy" class="commit">-</dd>
          <dt>Branch</dt><dd id="branch">-</dd>
        </dl>
        <div class="footer">
          Updated: <span id="updated">-</span> |
          <a href="/status.json">JSON</a>
        </div>
      </div>
      <script>
        async function update() {
          try {
            const r = await fetch('/status.json');
            const d = await r.json();
            document.getElementById('status').textContent = d.status;
            document.getElementById('status-dot').className = 'status-dot ' + d.status;
            const h = Math.floor(d.uptime_seconds / 3600);
            const m = Math.floor((d.uptime_seconds % 3600) / 60);
            document.getElementById('uptime').textContent = h + 'h ' + m + 'm';
            document.getElementById('deploy').textContent = d.deploy?.commit || 'unknown';
            document.getElementById('branch').textContent = d.deploy?.branch || 'unknown';
            document.getElementById('updated').textContent = new Date(d.generated_at).toLocaleTimeString();
          } catch(e) { console.error(e); }
        }
        update();
        setInterval(update, 30000);
      </script>
    </body>
    </html>
  '';
in
{
  # Ensure directories exist
  systemd.tmpfiles.rules = [
    "d ${statusDir} 0755 root root -"
    "d ${dropsDir} 0755 root root -"
    "d /var/lib/fort/nginx-upload-temp 0700 nginx nginx -"
  ];

  # Timer to regenerate status every 30 seconds
  systemd.timers.fort-host-status = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10s";
      OnUnitActiveSec = "30s";
    };
  };

  systemd.services.fort-host-status = {
    description = "Generate host status JSON";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = statusScript;
    };
  };

  # Socket activation for file upload handler
  systemd.sockets.fort-upload = {
    description = "Fort File Upload Socket";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ uploadSocket ];
    socketConfig = {
      SocketMode = "0660";
      SocketUser = "root";
      SocketGroup = "nginx";
    };
  };

  systemd.services.fort-upload = {
    description = "Fort File Upload Handler";
    requires = [ "fort-upload.socket" ];
    after = [ "fort-upload.socket" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${fortUpload}/bin/fort-upload";
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "journal";
    };
  };

  # Copy static HTML on activation
  system.activationScripts.fortHostStatusHtml.text = ''
    install -Dm0644 ${indexHtml} ${statusDir}/index.html
  '';

  # Nginx vhost for hostname.fort.domain
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;

    virtualHosts."${hostname}.fort.${domain}" = {
      forceSSL = true;
      sslCertificate = "/var/lib/fort/ssl/${domain}/fullchain.pem";
      sslCertificateKey = "/var/lib/fort/ssl/${domain}/key.pem";

      root = statusDir;

      locations."/" = {
        index = "index.html";
        extraConfig = ''
          if ($is_vpn = 0) {
            return 444;
          }
        '';
      };

      locations."/status.json" = {
        extraConfig = ''
          if ($is_vpn = 0) {
            return 444;
          }
          add_header Cache-Control "no-cache";
        '';
      };

      # File upload endpoint - VPN-only, no auth
      locations."/upload" = {
        extraConfig = ''
          if ($is_vpn = 0) {
            return 444;
          }

          # Only allow POST
          if ($request_method != POST) {
            return 405;
          }

          # No size limit - VPN is the trust boundary, disk space is the natural limit
          client_max_body_size 0;

          # Buffer uploads to persistent storage, not tmpfs
          client_body_temp_path /var/lib/fort/nginx-upload-temp;

          fastcgi_pass unix:${uploadSocket};
          include ${pkgs.nginx}/conf/fastcgi_params;
          fastcgi_param SCRIPT_NAME $uri;
          fastcgi_param REQUEST_METHOD $request_method;
          fastcgi_param CONTENT_TYPE $content_type;
          fastcgi_param CONTENT_LENGTH $content_length;
        '';
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];

  # Allow nginx to write to upload temp directory (ProtectSystem=strict blocks it otherwise)
  systemd.services.nginx.serviceConfig.ReadWritePaths = [ "/var/lib/fort/nginx-upload-temp" ];
}
