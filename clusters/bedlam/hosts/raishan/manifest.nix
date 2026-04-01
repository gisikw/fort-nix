rec {
  hostName = "raishan";
  device = "linode-85962061";

  roles = [ "beacon" ];

  apps = [
    {
      name = "hugo-blog";
      domain = "catdevurandom.com";
      contentDir = ./catdevurandom.com;
      title = "$ cat /dev/urandom";
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

      # Restricted jump-only user for external SSH access to dev-sandbox
      # Allows ProxyJump but no shell, no TTY, no agent forwarding
      config.users.users.jump = {
        isSystemUser = true;
        group = "jump";
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAkWpFxba7eQ4ve5ZiSS2cfQpFBqWQQhDPk75m8zWuga gisikw@K.Gisi-KVW36X1P09"
        ];
      };
      config.users.groups.jump = {};

      config.services.openssh.extraConfig = ''
        Match User jump
          PermitTTY no
          X11Forwarding no
          AllowAgentForwarding no
          ForceCommand ${pkgs.coreutils}/bin/false
      '';
    };
}
