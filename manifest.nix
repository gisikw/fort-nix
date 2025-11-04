let
  clusterContext = import ./common/cluster-context.nix { };

  defaultManifest =
    rec {
      fortConfig = {
        settings = {
          pubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC1fUAZLXWXgXfTKxejJHTT8rLpmDoTdJOxDV5m3lUHp fort";
          deployPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ6yMYrTeaT8CU7pjOVYQ1vP/dJTDan8KmBWSFngWbQ1 fort-deployer";
          domain = "gisi.network";
          dnsProvider = "porkbun";
        };
      };

      module =
        { config, lib, ... }:
        {
          options.fort = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };

          config.fort = fortConfig;
        };
    };

  resolvedManifest =
    if clusterContext.hasClusterManifest then
      import clusterContext.clusterManifestPath
    else
      defaultManifest;
in
resolvedManifest
// {
  fort =
    (resolvedManifest.fort or { })
    // {
      cluster =
        clusterContext
        // {
          manifest = resolvedManifest;
        };
    };
}
