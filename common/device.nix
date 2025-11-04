args@{
  self,
  nixpkgs,
  disko,
  impermanence,
  deviceDir,
  ...
}:
let
  rootManifest = import ../manifest.nix;
  cluster = rootManifest.fort.cluster;
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
        config.fort = {
          clusterName = cluster.clusterName;
          clusterDir = cluster.clusterDir;
          clusterHostsDir = cluster.hostsDir;
          clusterDevicesDir = cluster.devicesDir;
          clusterSettings = cluster.manifest.fortConfig.settings;
        };
      }
    ];
  };
}
