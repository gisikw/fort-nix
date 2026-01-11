args@{
  self,
  nixpkgs,
  disko,
  impermanence,
  deploy-rs,
  hostDir,
  agenix,
  comin,
  # Cluster-specific inputs (optional)
  home-config ? null,
  ...
}:
let
  cluster = import ../common/cluster-context.nix { };
  rootManifest = cluster.manifest;
  settings = rootManifest.fortConfig.settings;

  hostManifest = import (hostDir + "/manifest.nix");
  deviceManifest = import (cluster.devicesDir + "/${hostManifest.device}/manifest.nix");
  deviceProfileManifest = import ../device-profiles/${deviceManifest.profile}/manifest.nix;

  flatMap = f: xs: builtins.concatLists (map f xs);

  # Derive SSH keys for root access from principals with "root" role
  # Only SSH keys work for authorized_keys (filter out age keys)
  isSSHKey = k: builtins.substring 0 4 k == "ssh-";
  principalsWithRoot = builtins.filter
    (p: builtins.elem "root" (p.roles or [ ]))
    (builtins.attrValues settings.principals);
  rootAuthorizedKeys = builtins.filter isSSHKey (map (p: p.publicKey) principalsWithRoot);
  roles = map (r: import ../roles/${r}.nix) hostManifest.roles;
  # Default aspects that every host gets
  defaultAspects = [ "host-status" ];
  allAspects = defaultAspects ++ hostManifest.aspects ++ flatMap (r: r.aspects or [ ]) roles;
  allApps = hostManifest.apps ++ flatMap (r: r.apps or [ ]) roles;

  # Extra inputs to pass through to apps/aspects
  extraInputs = {
    inherit home-config;
  };

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
          extraInputs
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
          extraInputs
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
            extraInputs
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
        nix.settings.experimental-features = [ "nix-command" "flakes" ];
        # Include attic cache config if it exists (delivered by attic-key-sync)
        # TODO: Re-enable once attic is resilient to network loss
        # nix.extraOptions = ''
        #   !include /var/lib/fort/nix/attic-cache.conf
        # '';
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
      (import ./fort.nix ({
        inherit
          rootManifest
          hostManifest
          deviceManifest
          deviceProfileManifest
          ;
      }))
      (import ./fort/control-plane.nix {
        inherit
          rootManifest
          cluster
          ;
      })
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
        settings.principals.admin.privateKeyPath
      ];
      path =
        deploy-rs.lib.${deviceProfileManifest.system}.activate.nixos
          self.nixosConfigurations.${hostManifest.hostName};
    };
  };
}
