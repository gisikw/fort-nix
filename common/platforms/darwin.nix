# Darwin (macOS) platform builder
#
# Called by common/host.nix when deviceProfileManifest.platform == "darwin".
# Receives shared context (manifests, modules, inputs) and returns
# darwinConfigurations flake outputs.
#
# Darwin hosts are dev machines — no nginx, oauth2-proxy, ACME, control-plane,
# comin, disko, or impermanence. They get sops-nix for secrets and the
# shared app/aspect module composition.
#
{
  nix-darwin,
  nixpkgs,
  sops-nix,
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
        sops.age.sshKeyPaths = [
          "/etc/ssh/ssh_host_ed25519_key"
        ];

        # Admin user: passwordless sudo (matches NixOS root SSH pattern)
        environment.etc."sudoers.d/admin-nopasswd".text = "admin ALL=(ALL) NOPASSWD: ALL\n";

        # Deploy key access: nix-darwin's users.users.*.openssh.authorizedKeys doesn't
        # write to ~/.ssh/authorized_keys on macOS, so we manage it via activation script
        system.activationScripts.postActivation.text = let
          authorizedKeysFile = builtins.toFile "admin-authorized-keys"
            (builtins.concatStringsSep "\n" rootAuthorizedKeys + "\n");
        in ''
          mkdir -p /Users/admin/.ssh
          cp ${authorizedKeysFile} /Users/admin/.ssh/authorized_keys
          chmod 700 /Users/admin/.ssh
          chmod 600 /Users/admin/.ssh/authorized_keys
          chown -R admin:staff /Users/admin/.ssh
        '';
      }
      rootManifest.module
      hostManifest.module
      deviceProfileManifest.module
      sops-nix.darwinModules.sops
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
