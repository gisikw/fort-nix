{ users ? [], mesh ? false, rootManifest, deviceProfileManifest, ... }:
{ config, lib, ... }:
if (deviceProfileManifest.platform or "nixos") != "nixos" then
  throw "fort-nix: aspect 'mosquitto' is Linux-only (services.mosquitto NixOS module); remove it from this darwin host's manifest"
else
let
  vpnIpv4Prefix = rootManifest.fortConfig.settings.vpn.ipv4Prefix;

  # Every broker client was historically colocated on this host, so the
  # listener bound loopback only. `mesh = true` opens it to the fort mesh for
  # off-host clients (e.g. family-hub on ratched).
  #
  # Binding 0.0.0.0 rather than a specific mesh address: mesh IPs are assigned
  # by headscale, so hardcoding one here would silently break on re-issue. The
  # firewall rule below is what actually constrains reachability, and it is
  # scoped to the VPN source prefix — the port is NOT open to the LAN.
  listenAddress = if mesh then "0.0.0.0" else "127.0.0.1";
in
{
  # Broker users whose credential is not declared by another module on this
  # host (zigbee2mqtt, hass and frigate each declare their own) must be
  # declared here, or `config.sops.secrets.<name>` below is a missing attribute.
  sops.secrets = lib.listToAttrs (map (u: {
    name = u.secret;
    value = {
      sopsFile = u.passwordFile;
      format = "binary";
      mode = "0440";
      group = "mosquitto";
    };
  }) (builtins.filter (u: u ? passwordFile) users));

  services.mosquitto = {
    enable = true;
    listeners = [
      {
        address = listenAddress;
        port = 1883;
        users = lib.listToAttrs (map (u: {
          name = u.name;
          value = {
            passwordFile = config.sops.secrets.${u.secret}.path;
            acl = u.acl or [ "readwrite #" ];
          };
        }) users);
      }
    ];
  };

  # Source-scoped to the mesh. A global allowedTCPPorts entry would also expose
  # the broker to the LAN, where an unauthenticated scan would reach a service
  # that controls every light, lock, and sensor in the house.
  networking.firewall.extraCommands = lib.mkIf mesh ''
    iptables -w -A nixos-fw -p tcp -s ${vpnIpv4Prefix} --dport 1883 \
      -m comment --comment "mosquitto-mesh" -j nixos-fw-accept
  '';
}
