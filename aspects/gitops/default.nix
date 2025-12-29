{
  rootManifest,
  hostManifest,
  cluster,
  ...
}:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  forgeConfig = rootManifest.fortConfig.forge;
  credDir = "/var/lib/fort-git";
  tokenFile = "${credDir}/deploy-token";

  repoUrl = "https://git.${domain}/${forgeConfig.org}/${forgeConfig.repo}.git";
in
{
  # Ensure credential directory exists
  systemd.tmpfiles.rules = [
    "d ${credDir} 0700 root root -"
  ];

  services.comin = {
    enable = true;

    remotes = [{
      name = "origin";
      url = repoUrl;
      branches.main.name = "release";

      # Auth via deploy token distributed by forge
      auth.access_token_path = tokenFile;
    }];

    # Point to this host's flake within the repo
    # Each host has its own flake.nix at clusters/<cluster>/hosts/<hostname>/
    repositorySubdir = "clusters/${cluster.clusterName}/hosts/${hostManifest.hostName}";
  };

  # Comin needs git in PATH for fetching
  environment.systemPackages = [ pkgs.git ];
}
