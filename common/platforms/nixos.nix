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
        sops.age.sshKeyPaths = [ "/persist/system/etc/ssh/ssh_host_ed25519_key" ];

        # zram swap on all hosts — compressed in-memory swap prevents OOM kills
        # from taking down the entire box (the failure mode that wedges drhorrible/ratched).
        zramSwap.enable = true;
        zramSwap.memoryPercent = 25;

        users.users.root.openssh.authorizedKeys.keys = rootAuthorizedKeys;
      }
      # Gapped ESP. /boot is only ever written during switch-to-configuration;
      # the rest of the time an idle mounted FAT partition is just exposure to
      # a power cut (a bootloader was lost this way once). Mount on demand and
      # unmount a minute after the last touch. Recovery from a corrupted ESP on
      # a Beelink is an Ubuntu live USB -> sshd -> chroot, not the NixOS ISO.
      # Gated on "there is an ESP": systemd-boot, or GRUB with efiSupport (the
      # Beelinks). raishan is BIOS GRUB on Linode with no real /boot filesystem.
      ({ config, lib, ... }: {
        # mkIf must wrap the attrset: gating only `.options` still creates a
        # /boot entry with no device, which fails eval on raishan (CI caught it).
        fileSystems = lib.mkIf (
          config.boot.loader.systemd-boot.enable
          || (config.boot.loader.grub.enable && config.boot.loader.grub.efiSupport)
        ) {
          "/boot".options = [
            "noauto"
            "x-systemd.automount"
            "x-systemd.idle-timeout=1min"
          ];
        };
      })
      impermanence.nixosModules.impermanence
      rootManifest.module
      hostManifest.module
      deviceProfileManifest.module
      disko.nixosModules.disko
      sops-nix.nixosModules.sops
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
      (import ../fort/overlays.nix {
        inherit
          rootManifest
          hostManifest
          cluster
          ;
      })
      (import ../fort/tracked.nix {
        inherit
          rootManifest
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
