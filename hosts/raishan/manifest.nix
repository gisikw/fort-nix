rec {
  hostName = "raishan";
  device = "linode-85962061";

  roles = [ "beacon" ];

  apps = [ "pocket-id" ];

  aspects = [ "observable" ];

  module =
    { config, pkgs, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
      config.environment.systemPackages = with pkgs; [ neovim ];
    };
}
