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

# Darwin: tailscale service + automatic mesh enrollment via launchd
++ lib.optionals (platform == "darwin") [
  {
    services.tailscale.enable = true;
  }

  # Auto-enroll in mesh on activation (no-op if already connected)
  (lib.mkIf hasAuthKey (let
    enrollScript = pkgs.writeShellScript "fort-mesh-enroll" ''
      set -euo pipefail

      # Wait for tailscaled to be ready
      for i in $(seq 1 30); do
        ${pkgs.tailscale}/bin/tailscale status >/dev/null 2>&1 && break
        sleep 2
      done

      # Already connected to our mesh? Nothing to do.
      if ${pkgs.tailscale}/bin/tailscale status 2>/dev/null | grep -q "mesh.${domain}"; then
        exit 0
      fi

      AUTH_KEY=$(cat ${config.age.secrets.auth-key.path})
      ${pkgs.tailscale}/bin/tailscale up \
        --login-server="https://mesh.${domain}" \
        --hostname="${hostManifest.hostName}" \
        --accept-dns=true \
        --accept-routes=true \
        --authkey="$AUTH_KEY"
    '';
  in {
    launchd.daemons.fort-mesh-enroll = {
      serviceConfig = {
        Label = "network.gisi.fort.mesh-enroll";
        ProgramArguments = [ "${enrollScript}" ];
        RunAtLoad = true;
        StandardOutPath = "/var/log/fort-mesh-enroll.log";
        StandardErrorPath = "/var/log/fort-mesh-enroll.log";
      };
    };

    # Keep the manual script available for troubleshooting
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
  }))
])
