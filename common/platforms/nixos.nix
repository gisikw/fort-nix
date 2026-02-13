# NixOS platform builder
#
# Called by common/host.nix when deviceProfileManifest.platform == "nixos".
# Receives shared context (manifests, modules, inputs) and returns
# nixosConfigurations + deploy.nodes flake outputs.
#
{
  self,
  nixpkgs,
  disko,
  impermanence,
  deploy-rs,
  agenix,
  comin,
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
}:
let
  settings = rootManifest.fortConfig.settings;
in
{
  nixosConfigurations.${hostManifest.hostName} = nixpkgs.lib.nixosSystem {
    system = deviceProfileManifest.system;
    modules = [
      {
        nix.settings = {
          experimental-features = [ "nix-command" "flakes" ];
          fallback = true;
          connect-timeout = 5;
          stalled-download-timeout = 60;
          trusted-substituters = [ "https://cache.${settings.domain}/fort" ];
        };
        nix.extraOptions = ''
          !include /var/lib/fort/nix/attic-cache.conf
        '';
        nixpkgs.config.allowUnfree = true;
        system.stateVersion = deviceManifest.stateVersion;
        networking.hostName = hostManifest.hostName;
        environment.persistence."/persist/system" = {
          enable = deviceProfileManifest.impermanent;
          directories = [
            "/var/lib"
          ];
          files = [
            "/etc/machine-id"
            "/etc/ssh/ssh_host_ed25519_key"
            "/etc/ssh/ssh_host_ed25519_key.pub"
            "/etc/ssh/ssh_host_rsa_key"
            "/etc/ssh/ssh_host_rsa_key.pub"
          ];
        };
        age.identityPaths = [ "/persist/system/etc/ssh/ssh_host_ed25519_key" ];

        users.users.root.openssh.authorizedKeys.keys = rootAuthorizedKeys;
      }
      impermanence.nixosModules.impermanence
      rootManifest.module
      hostManifest.module
      deviceProfileManifest.module
      disko.nixosModules.disko
      agenix.nixosModules.age
      comin.nixosModules.comin
      (cluster.devicesDir + "/${hostManifest.device}/hardware-configuration.nix")
      {
        config.fort = {
          clusterName = cluster.clusterName;
          clusterDir = cluster.clusterDir;
          clusterHostsDir = cluster.hostsDir;
          clusterDevicesDir = cluster.devicesDir;
        };
      }
      (import ../fort-options.nix ({
        inherit rootManifest cluster;
      }))
      (import ../fort.nix ({
        inherit
          rootManifest
          hostManifest
          deviceManifest
          deviceProfileManifest
          cluster
          ;
      }))
      (import ../fort/control-plane.nix {
        inherit
          rootManifest
          cluster
          ;
      })
      (import ../fort/runtime-packages.nix {
        inherit
          cluster
          ;
      })
    ]
    ++ appModules
    ++ aspectModules;
  };

  deploy.nodes.${hostManifest.hostName} = {
    hostname = "<dynamic>";
    profiles.system = {
      sshUser = "root";
      sshOpts = [
        "-i"
        settings.principals.admin.privateKeyPath
      ];
      path =
        deploy-rs.lib.${deviceProfileManifest.system}.activate.nixos
          self.nixosConfigurations.${hostManifest.hostName};
    };
  };
}
