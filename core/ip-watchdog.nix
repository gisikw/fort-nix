{ config, lib, pkgs, ... }:

let
  domain = config.networking.domain;

  watchdogScript = pkgs.writeShellScript "ip-watchdog" ''
    set -eu

    STATE="/var/lib/core/wan-ip"

    # Detect current WAN IP
    CURRENT=$(${pkgs.curl}/bin/curl -sf --max-time 10 https://api.ipify.org || true)
    if [ -z "$CURRENT" ]; then
      # Fallback resolver
      CURRENT=$(${pkgs.curl}/bin/curl -sf --max-time 10 https://ifconfig.me || true)
    fi

    if [ -z "$CURRENT" ]; then
      echo "Failed to detect WAN IP"
      exit 1
    fi

    STORED=$(cat "$STATE" 2>/dev/null || echo "")

    if [ "$CURRENT" = "$STORED" ]; then
      exit 0
    fi

    echo "WAN IP changed: $STORED → $CURRENT"
    echo "$CURRENT" > "$STATE"

    # Update VPS relay's nginx upstream to point to new IP
    VPS_KEY="/var/lib/core/vps-key"
    VPS_HOST="relay.${domain}"

    if [ -f "$VPS_KEY" ]; then
      echo "Updating VPS proxy backend..."
      ${pkgs.openssh}/bin/ssh -i "$VPS_KEY" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        "root@$VPS_HOST" \
        "sed -i 's|proxy_pass .*:8443;|proxy_pass $CURRENT:8443;|' /etc/nginx/stream-core.conf && nginx -s reload" \
        2>&1 || echo "VPS update failed (will retry next cycle)"
    else
      echo "No VPS key at $VPS_KEY — skipping proxy update"
    fi

    # Update Porkbun DNS if configured (Option A fallback)
    REGISTRAR="/var/lib/core/registrar.env"
    if [ -f "$REGISTRAR" ]; then
      # shellcheck source=/dev/null
      . "$REGISTRAR"
      if [ -n "''${PORKBUN_API_KEY:-}" ] && [ -n "''${PORKBUN_SECRET_KEY:-}" ]; then
        echo "Updating DNS A record..."
        ${pkgs.curl}/bin/curl -sf -X POST \
          "https://api.porkbun.com/api/json/v3/dns/editByNameType/${domain}/A" \
          -H "Content-Type: application/json" \
          -d "{
            \"apikey\": \"$PORKBUN_API_KEY\",
            \"secretapikey\": \"$PORKBUN_SECRET_KEY\",
            \"content\": \"$CURRENT\",
            \"ttl\": \"300\"
          }" 2>&1 || echo "DNS update failed (will retry next cycle)"
      fi
    fi
  '';
in
{
  systemd.services.ip-watchdog = {
    description = "Monitor WAN IP and update VPS proxy + DNS";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = watchdogScript;
    };
  };

  systemd.timers.ip-watchdog = {
    description = "Check WAN IP every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };
}
