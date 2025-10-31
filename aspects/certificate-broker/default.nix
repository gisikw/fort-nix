{
  rootManifest,
  ...
}:
{ config, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
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
