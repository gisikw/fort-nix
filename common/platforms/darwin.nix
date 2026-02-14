# Darwin (macOS) platform builder
#
# Called by common/host.nix when deviceProfileManifest.platform == "darwin".
# Receives shared context (manifests, modules, inputs) and returns
# darwinConfigurations flake outputs.
#
# Darwin hosts are dev machines — no nginx, oauth2-proxy, ACME, control-plane,
# comin, disko, or impermanence. They get agenix for secrets and the shared
# app/aspect module composition.
#
{
  nix-darwin,
  nixpkgs,
  agenix,
  # Shared context from host.nix
  hostManifest,
  deviceManifest,
  deviceProfileManifest,
  rootManifest,
  cluster,
  rootAuthorizedKeys,
  appModules,
  aspectModules,
  extraInputs,
  ...
}:
let
  settings = rootManifest.fortConfig.settings;
in
{
  darwinConfigurations.${hostManifest.hostName} = nix-darwin.lib.darwinSystem {
    system = deviceProfileManifest.system;
    modules = [
      {
        # Determinate manages the Nix daemon; disable nix-darwin's Nix management
        nix.enable = false;
        nixpkgs.config.allowUnfree = true;
        system.stateVersion = 6;
        system.primaryUser = "admin";
        networking.hostName = hostManifest.hostName;
        # Use SSH host key as age identity (agenix derives age key from ed25519)
        # Falls back to explicit age key if present
        age.identityPaths = [
          "/etc/ssh/ssh_host_ed25519_key"
          "/var/lib/fort/age-key.txt"
        ];

        # Admin user: deploy key access + passwordless sudo (matches NixOS root SSH pattern)
        users.users.admin.openssh.authorizedKeys.keys = rootAuthorizedKeys;
        environment.etc."sudoers.d/admin-nopasswd".text = "admin ALL=(ALL) NOPASSWD: ALL\n";
      }
      rootManifest.module
      hostManifest.module
      deviceProfileManifest.module
      agenix.darwinModules.default
      (import ../fort-options.nix ({
        inherit rootManifest cluster;
      }))
      {
        config.fort = {
          clusterName = cluster.clusterName;
          clusterDir = cluster.clusterDir;
          clusterHostsDir = cluster.hostsDir;
          clusterDevicesDir = cluster.devicesDir;
        };
      }
    ]
    ++ appModules
    ++ aspectModules;
  };
}
