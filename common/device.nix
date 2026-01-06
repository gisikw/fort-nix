{
  nixpkgs,
  disko,
  impermanence,
  deviceDir,
  ...
}:
let
  cluster = import ../common/cluster-context.nix { };
  rootManifest = cluster.manifest;
  deviceManifest = import (deviceDir + "/manifest.nix");
  deviceProfileManifest = import ../device-profiles/${deviceManifest.profile}/manifest.nix;
in
{
  nixosConfigurations.${deviceManifest.uuid} = nixpkgs.lib.nixosSystem {
    system = deviceProfileManifest.system;
    modules = [
      rootManifest.module
      impermanence.nixosModules.impermanence
      {
        system.stateVersion = deviceManifest.stateVersion;
        networking.hostName = "fort-${builtins.substring 0 8 deviceManifest.uuid}";
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
      }
      deviceProfileManifest.module
      disko.nixosModules.disko
      (deviceDir + "/hardware-configuration.nix")
      {
        # Define fort.cluster for device builds (minimal, just accepts freeform config)
        options.fort.cluster = nixpkgs.lib.mkOption {
          type = nixpkgs.lib.types.submodule {
            freeformType = nixpkgs.lib.types.attrsOf nixpkgs.lib.types.anything;
          };
          default = { };
          description = "Cluster-level config (settings, forge)";
        };
        config.fort = {
          clusterName = cluster.clusterName;
          clusterDir = cluster.clusterDir;
          clusterHostsDir = cluster.hostsDir;
          clusterDevicesDir = cluster.devicesDir;
        };
      }
    ];
  };
}
