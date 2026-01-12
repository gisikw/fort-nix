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
  authKeyPath = ./auth-key.age;
  hasAuthKey = builtins.pathExists authKeyPath;

  # RPC handler that returns this host's LAN IP (source IP for default route)
  lanIpHandler = pkgs.writeShellScript "handler-lan-ip" ''
    # Get the source IP used for the default route (excludes mesh interface)
    lan_ip=$(${pkgs.iproute2}/bin/ip -4 route get 1.1.1.1 2>/dev/null | ${pkgs.gnugrep}/bin/grep -oP 'src \K\S+' || echo "")

    if [ -z "$lan_ip" ]; then
      ${pkgs.jq}/bin/jq -n '{"error": "no default route"}'
    else
      ${pkgs.jq}/bin/jq -n --arg ip "$lan_ip" '{"lan_ip": $ip}'
    fi
  '';
in
{
  age.secrets = lib.mkIf hasAuthKey {
    auth-key = {
      file = ./auth-key.age;
      mode = "0400";
    };
  };

  services.tailscale = lib.mkIf hasAuthKey {
    enable = true;
    interfaceName = "fortmesh0";
    useRoutingFeatures = "client";
    extraUpFlags = [
      "--login-server=https://mesh.${rootManifest.fortConfig.settings.domain}"
      "--hostname=${hostManifest.hostName}"
      "--accept-dns=true"
      "--accept-routes=true"
    ];
    authKeyFile = config.age.secrets.auth-key.path;
  };

  # Expose lan-ip capability for LAN DNS lookups
  fort.host.capabilities.lan-ip = {
    handler = lanIpHandler;
    mode = "rpc";
    description = "Return this host's LAN IP address";
  };
}
