{
  rootManifest,
  ...
}:
{ config, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;

  # Async handler for ssl-cert capability
  # Receives aggregate requests, returns same certs for all consumers (wildcard)
  # Input: {"origin:ssl-cert-default": {"request": {...}}, ...}
  # Output: {"origin:ssl-cert-default": {cert, key, chain, domain}, ...}
  sslCertHandler = pkgs.writeShellScript "handler-ssl-cert" ''
    set -euo pipefail

    cert_dir="/var/lib/acme/${domain}"

    if [ ! -d "$cert_dir" ]; then
      echo '{"error": "certificate not found for domain"}' >&2
      exit 1
    fi

    # Read and base64-encode the cert files (same for all consumers - wildcard)
    cert=$(${pkgs.coreutils}/bin/base64 -w0 "$cert_dir/fullchain.pem")
    key=$(${pkgs.coreutils}/bin/base64 -w0 "$cert_dir/key.pem")
    chain=$(${pkgs.coreutils}/bin/base64 -w0 "$cert_dir/chain.pem")

    # Build response template
    response=$(${pkgs.jq}/bin/jq -n \
      --arg cert "$cert" \
      --arg key "$key" \
      --arg chain "$chain" \
      --arg domain "${domain}" \
      '{domain: $domain, cert: $cert, key: $key, chain: $chain}')

    # Read aggregate input and return same response for all keys
    ${pkgs.jq}/bin/jq --argjson resp "$response" 'to_entries | map({key: .key, value: $resp}) | from_entries'
  '';
in
{
  age.secrets.dns-provider-env = {
    file = ./dns-provider.env.age;
    mode = "0400";
  };

  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "admin@${domain}";
      dnsPropagationCheck = false;
    };

    certs.${domain} = {
      inherit domain;
      extraDomainNames = [
        "*.${domain}"
        "*.fort.${domain}"
      ];
      dnsProvider = rootManifest.fortConfig.settings.dnsProvider;
      environmentFile = config.age.secrets.dns-provider-env.path;
    };
  };

  # Expose ssl-cert capability via agent API
  fort.host.capabilities.ssl-cert = {
    handler = sslCertHandler;
    mode = "async";  # Aggregate handler, returns same certs to all consumers
    triggers = {
      initialize = true;  # Push certs on boot
      systemd = [ "acme-${domain}.service" ];  # Push on renewal
    };
    description = "Return cluster SSL certificates (ACME-managed)";
  };

  # Ensure SSL directory exists (needed for impermanence hosts)
  systemd.tmpfiles.rules = [
    "d /var/lib/fort/ssl/${domain} 0755 root root -"
  ];

  # Copy ACME certs to standard location for local nginx
  # Other hosts get this via control plane callback
  systemd.services."acme-${domain}".postStart = ''
    cp -L /var/lib/acme/${domain}/fullchain.pem /var/lib/fort/ssl/${domain}/
    cp -L /var/lib/acme/${domain}/key.pem /var/lib/fort/ssl/${domain}/
    cp -L /var/lib/acme/${domain}/chain.pem /var/lib/fort/ssl/${domain}/
    chown -R root:root /var/lib/fort/ssl
    chmod -R u=rwX,go=rX /var/lib/fort/ssl
  '';

  systemd.timers."acme-sync" = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnUnitActiveSec = "10m";
  };

  systemd.services."acme-sync" = {
    path = with pkgs; [
      tailscale
      jq
      rsync
      openssh
    ];
    script = ''
      SSH_OPTS="-i /root/.ssh/deployer_ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=10"

      mesh=$(tailscale status --json)
      user=$(echo $mesh | jq -r '.User | to_entries[] | select(.value.LoginName == "fort") | .key')
      peers=$(echo $mesh | jq -r --arg user "$user" '.Peer | to_entries[] | select(.value.UserID == ($user | tonumber)) | .value.DNSName')

      for peer in localhost $peers; do
        echo "Syncing ACME to $peer..."
        if rsync -az \
          --rsync-path="mkdir -p /var/lib/fort/ssl/${domain} && rsync" \
          -e "ssh $SSH_OPTS" \
          "/var/lib/acme/${domain}/" "$peer:/var/lib/fort/ssl/${domain}/"; then
            echo "Reloading nginx on $peer..."
            ssh $SSH_OPTS "$peer" '
              echo "Fixing ACME permissions..."
              chown -R root:root /var/lib/fort/ssl &&
              chmod -R u=rwX,go=rX /var/lib/fort/ssl &&
              systemctl reload nginx 2>/dev/null || true
            '
        else
          echo "Sync failed for $peer, skipping reload"
        fi
      done
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
  };
}
