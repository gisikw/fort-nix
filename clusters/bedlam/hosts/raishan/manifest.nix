rec {
  hostName = "raishan";
  device = "linode-85962061";

  roles = [ "beacon" ];

  apps = [
    {
      name = "hugo-blog";
      domain = "catdevurandom.com";
      contentDir = ./catdevurandom.com;
      title = "cat /dev/urandom";
      description = "Random thoughts from a random cat";
    }
  ];

  aspects = [
    "observable"
    { name = "gitops"; manualDeploy = true; }
  ];

  module =
    { config, pkgs, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
      config.environment.systemPackages = with pkgs; [ neovim ];
    };
}
