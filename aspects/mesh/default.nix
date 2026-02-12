{
  rootManifest,
  hostManifest,
  deviceProfileManifest,
  ...
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  platform = deviceProfileManifest.platform or "nixos";
  domain = rootManifest.fortConfig.settings.domain;

  authKeyPath = ./auth-key.age;
  hasAuthKey = builtins.pathExists authKeyPath;
in
lib.mkMerge ([
  # Shared: agenix secret (works on both platforms)
  (lib.mkIf hasAuthKey {
    age.secrets.auth-key = {
      file = ./auth-key.age;
      mode = "0400";
    };
  })
]

# NixOS: full tailscale service with auto-auth + lan-ip capability
++ lib.optionals (platform == "nixos") [
  {
    services.tailscale = lib.mkIf hasAuthKey {
      enable = true;
      interfaceName = "fortmesh0";
      useRoutingFeatures = "client";
      extraUpFlags = [
        "--login-server=https://mesh.${domain}"
        "--hostname=${hostManifest.hostName}"
        "--accept-dns=true"
        "--accept-routes=true"
      ];
      authKeyFile = config.age.secrets.auth-key.path;
    };

    # Expose lan-ip capability for LAN DNS lookups
    fort.host.capabilities.lan-ip = {
      handler = "${import ./provider { inherit pkgs; }}/bin/lan-ip-provider";
      mode = "rpc";
      description = "Return this host's LAN IP address";
    };
  }
]

# Darwin: tailscale service + setup script for manual auth
++ lib.optionals (platform == "darwin") [
  {
    services.tailscale.enable = true;

    # Provide a setup script for initial mesh enrollment
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "fort-mesh-join" ''
        echo "Joining fort mesh as ${hostManifest.hostName}..."
        sudo ${pkgs.tailscale}/bin/tailscale up \
          --login-server="https://mesh.${domain}" \
          --hostname="${hostManifest.hostName}" \
          --accept-dns=true \
          --accept-routes=true \
          "$@"
      '')
    ];
  }
])
