{ rootManifest, ... }:
{ pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
in
{
  environment.systemPackages = [ pkgs.deploy-rs ];

  age.secrets.deploy-key = {
    file = ./deployer-key.age;
    mode = "0400";
    owner = "root";
    path = "/root/.ssh/deployer_ed25519";
  };

  programs.ssh.extraConfig = ''
    Host *.fort.${domain}
      IdentityFile /root/.ssh/deployer_ed25519
  '';
}
