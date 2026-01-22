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

  # Go handler for lan-ip capability
  lanIpProvider = import ./provider { inherit pkgs; };
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
    handler = "${lanIpProvider}/bin/lan-ip-provider";
    mode = "rpc";
    description = "Return this host's LAN IP address";
  };
}
