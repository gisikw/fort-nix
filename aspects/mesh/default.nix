{
  rootManifest,
  hostManifest,
  ...
}:
{
  config,
  lib,
  ...
}:
let
  authKeyPath = ./auth-key.age;
  hasAuthKey = builtins.pathExists authKeyPath;
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
}
