{ rootManifest, ... }:
{ pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
in
{
  environment.systemPackages = [ pkgs.deploy-rs ];

  sops.secrets.deploy-key = {
    sopsFile = ./deployer-key.sops;
    format = "binary";
    mode = "0400";
    owner = "root";
    path = "/root/.ssh/deployer_ed25519";
  };

  programs.ssh.extraConfig = ''
    Host *.fort.${domain}
      IdentityFile /root/.ssh/deployer_ed25519
  '';
}
