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
  cominStore = "/var/lib/comin/store.json";
  deployRsInfo = "/var/lib/fort/deploy-info.json";

  cominRepo = "/var/lib/comin/repository";

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

      # Get pending SHA from comin repository HEAD (what's been fetched but maybe not deployed)
      if [ -d "${cominRepo}" ]; then
        pending_msg=$(${pkgs.git}/bin/git -C "${cominRepo}" log -1 --format=%s HEAD 2>/dev/null || echo "")
        pending_sha=$(echo "$pending_msg" | sed -n 's/^release: \([a-f0-9]*\) -.*/\1/p')
        if [ -n "$pending_sha" ]; then
          deploy_info=$(echo "$deploy_info" | ${pkgs.jq}/bin/jq --arg pending "$pending_sha" '. + {pending: $pending}')
        fi
      fi
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
      --arg generated "$(date -Iseconds)" \
      '{
        hostname: $hostname,
        status: $status,
        uptime_seconds: $uptime,
        failed_units: $failed,
        deploy: $deploy,
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
  # Ensure status directory exists
  systemd.tmpfiles.rules = [
    "d ${statusDir} 0755 root root -"
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
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
