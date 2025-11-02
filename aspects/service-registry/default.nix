{ hostManifest, rootManifest, ... }:
{ pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  serviceDomain =
    svc:
    let
      sub = if svc ? subdomain && svc.subdomain != null then svc.subdomain else svc.name;
    in
    "${sub}.${domain}";
  hostFiles = builtins.readDir ../../hosts;
  hosts = builtins.mapAttrs (name: _: import (../../hosts/${name}/manifest.nix)) hostFiles;
  beacons = builtins.filter (h: builtins.elem "beacon" h.roles) (builtins.attrValues hosts);
  beaconHost = (builtins.head beacons).hostName;
in
{
  systemd.timers."fort-service-registry" = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnUnitActiveSec = "10m";
  };

  systemd.services."fort-service-registry" = {
    path = with pkgs; [
      tailscale
      jq
      openssh
      bind.dnsutils
      gawk
      iproute2
    ];
    script = ''
      SSH_OPTS="-i /root/.ssh/deployer_ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=10"
      mesh=$(tailscale status --json)
      user=$(echo $mesh | jq -r '.User | to_entries[] | select(.value.LoginName == "fort") | .key')
      peers=$(echo $mesh | jq -r --arg user "$user" '.Peer | to_entries[] | select(.value.UserID == ($user | tonumber)) | .value.DNSName')
      host_lan_ip=$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="src") print $(i+1)}')

      services=$(
        for peer in ${hostManifest.hostName}.fort.${domain} $peers; do
          output=$(ssh $SSH_OPTS -n "root@$peer" "
            ip -4 -o addr show fortmesh0 2>/dev/null | head -n1 || echo 'NOFORT'
            ip -4 route get $host_lan_ip 2>/dev/null | head -n1 || echo 'NOROUTE'
            cat /var/lib/fort/services.json 2>/dev/null || echo '[]'
          ")

          vpn_ip_line=$(echo "$output" | sed -n '1p')
          lan_ip_line=$(echo "$output" | sed -n '2p')
          services=$(echo "$output" | sed -n '3,$p')

          vpn_ip=$(echo "$vpn_ip_line" | awk '{print $4}' | cut -d/ -f1)
          lan_ip=$(echo "$lan_ip_line" | awk '{for (i=1; i<=NF; i++) if ($i=="src") print $(i+1)}')

          echo "$services" | jq \
            --arg peer "$peer" \
            --arg vpn_ip "$vpn_ip" \
            --arg lan_ip "$lan_ip" \
            '.[] |= . + { hostname: $peer, vpn_ip: $vpn_ip, lan_ip: $lan_ip }'
        done | jq -s 'add' | jq '
            map(
              if has("subdomain") and (.subdomain != null) then
                . + { fqdn: (.subdomain + ".${domain}") }
              else
                . + { fqdn: (.name + ".${domain}") }
              end
            )
        '
      )

      echo $services \
        | jq 'map({ name: .fqdn, type: "A", value: .vpn_ip })' \
        | ssh $SSH_OPTS "root@${beaconHost}.fort.${domain}" "tee /var/lib/headscale/extra-records.json >/dev/null"

      echo $services \
        | jq -r '.[] | select(.visibility != "vpn") | "\(.lan_ip) \(.fqdn)"' \
        | tee /var/lib/coredns/custom.conf >/dev/null
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
  };
}
