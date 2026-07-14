rec {
  hostName = "drhorrible";
  device = "801cc75b-726d-b24a-b46b-7015fb5bf9cd";

  roles = [ "forge" ];

  apps = [
    "fort-tokens"
    "homepage"
    "overlay-registry"
    "pocket-id"
    "provisioner"
  ];

  overlays = {
    # Coffer secrets broker (server role: coffer-server + coffer-web).
    # CI registers the overlay on push to main once go.mod exists.
    coffer = {
      package = "infra/coffer";
      config = {
        role = "server";
        port = "7787";
        webPort = "7788";
      };
    };
  };
  aspects = [
    "mesh"
    "observable"
    "ldap"
    "backup-client"
    { name = "gitops"; manualDeploy = true; }
  ];

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
