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
        nix.settings = {
          experimental-features = [ "nix-command" "flakes" ];
          fallback = true;
          connect-timeout = 5;
          stalled-download-timeout = 60;
          trusted-substituters = [ "https://cache.${settings.domain}/fort" ];
        };
        nixpkgs.config.allowUnfree = true;
        networking.hostName = hostManifest.hostName;
        age.identityPaths = [ "/var/lib/fort/age-key.txt" ];
      }
      rootManifest.module
      hostManifest.module
      deviceProfileManifest.module
      agenix.darwinModules.default
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
