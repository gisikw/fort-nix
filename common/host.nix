args@{
  self,
  nixpkgs,
  disko,
  impermanence,
  deploy-rs,
  hostDir,
  agenix,
  ...
}:
let
  rootManifest = import ../manifest.nix;
  cluster = rootManifest.fort.cluster;

  hostManifest = import (hostDir + "/manifest.nix");
  deviceManifest = import (cluster.devicesDir + "/${hostManifest.device}/manifest.nix");
  deviceProfileManifest = import ../device-profiles/${deviceManifest.profile}/manifest.nix;

  flatMap = f: xs: builtins.concatLists (map f xs);
  roles = map (r: import ../roles/${r}.nix) hostManifest.roles;
  allAspects = hostManifest.aspects ++ flatMap (r: r.aspects or [ ]) roles;
  allApps = hostManifest.apps ++ flatMap (r: r.apps or [ ]) roles;

  mkModule =
    type: mod:
    if builtins.isString mod then
      import ../${type}s/${mod} {
        inherit
          rootManifest
          hostManifest
          deviceManifest
          deviceProfileManifest
          cluster
          ;
      }

    else if builtins.isFunction mod then
      mod {
        inherit
          rootManifest
          hostManifest
          deviceManifest
          deviceProfileManifest
          cluster
          ;
      }

    else if builtins.isAttrs mod && mod ? name then
      import ../${type}s/${mod.name} (
        {
          inherit
            rootManifest
            hostManifest
            deviceManifest
            deviceProfileManifest
            cluster
            ;
        }
        // (builtins.removeAttrs mod [ "name" ])
      )

    else
      throw "Invalid ${type} spec: expected string, function, or { name = ... } attrset, got ${builtins.typeOf mod}";
in
{
  nixosConfigurations.${hostManifest.hostName} = nixpkgs.lib.nixosSystem {
    system = deviceProfileManifest.system;
    modules = [
      {
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

        users.users.root.openssh.authorizedKeys.keys = [ rootManifest.fortConfig.settings.deployPubkey ];
      }
      impermanence.nixosModules.impermanence
      rootManifest.module
      hostManifest.module
      deviceProfileManifest.module
      disko.nixosModules.disko
      agenix.nixosModules.age
      (cluster.devicesDir + "/${hostManifest.device}/hardware-configuration.nix")
      {
        config.fort = {
          clusterName = cluster.clusterName;
          clusterDir = cluster.clusterDir;
          clusterHostsDir = cluster.hostsDir;
          clusterDevicesDir = cluster.devicesDir;
          clusterSettings = cluster.manifest.fortConfig.settings;
        };
      }
      (import ./fort.nix ({
        inherit
          rootManifest
          hostManifest
          deviceManifest
          deviceProfileManifest
          ;
      }))
    ]
    ++ map (mkModule "app") allApps
    ++ map (mkModule "aspect") allAspects;
  };

  deploy.nodes.${hostManifest.hostName} = {
    hostname = "<dynamic>";
    profiles.system = {
      sshUser = "root";
      sshOpts = [
        "-i"
        "~/.ssh/fort"
      ];
      path =
        deploy-rs.lib.${deviceProfileManifest.system}.activate.nixos
          self.nixosConfigurations.${hostManifest.hostName};
    };
  };
}
