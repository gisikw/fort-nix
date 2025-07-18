{ config, pkgs, lib, fort, ... }:
let
  hmacSecretPath = config.age.secrets.hmac_key.path;
in
{
  systemd.services.fort-announce = {
    description = "Announce this host's IP to the fort DNS registry";
    serviceConfig.Type = "simple";
    path = [ pkgs.iproute2 pkgs.curl pkgs.gawk pkgs.coreutils pkgs.openssl pkgs.age ];

    script = ''
      set -e
      self=$(ip -4 route get 1.1.1.1 | awk '{print $7}')

      HOSTS="$self ${fort.host}.hosts.${fort.settings.domain}
      $self ${fort.device}.devices.${fort.settings.domain}"
      TIMESTAMP=$(date +%s)
      payload=$(mktemp)
      echo "$HOSTS" > "$payload"
      age -r "${fort.settings.registry_pubkey}" -o "$payload.enc" "$payload"

      printf "%s" "$TIMESTAMP" >> "$payload"
      HMAC_KEY=$(tr -d '\n' < "${hmacSecretPath}")
      HMAC=$(openssl dgst -sha256 -hmac "$HMAC_KEY" -binary "$payload" | openssl base64)

      max_attempts=10
      attempt=1
      while true; do
        if curl -sSf -XPOST http://ns.${fort.settings.domain}:60452 \
          -H "Content-Type: application/octet-stream" \
          -H "X-Timestamp: $TIMESTAMP" \
          -H "X-Signature: $HMAC" \
          --data-binary @"$payload.enc"; then
          echo "✅ DNS announce succeeded"
          break
        fi

        if [ "$attempt" -ge "$max_attempts" ]; then
          echo "❌ DNS announce failed after $attempt attempts" >&2
          exit 1
        fi

        delay=$((attempt * 10))
        echo "⏳ Attempt $attempt failed. Retrying in $delay seconds..."
        sleep $delay
        attempt=$((attempt + 1))
      done
    '';
  };

  systemd.timers.fort-announce = {
    description = "Periodically announce this host to fort-registry";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15s";
      OnUnitInactiveSec = "2min";
      AccuracySec = "15s";
      Unit = "fort-announce.service";
    };
  };

  age.secrets.hmac_key = {
    file = ../../secrets/hmac_key.age;
    owner = "root";
    group = "root";
  };
}
