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
    "tiltshift"
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

      # Familiar fleet rendezvous. Off-mesh fleet nodes (the work laptop) hold
      # a reverse tunnel into azula's sshd; this forwards raishan:2222 to it
      # over the mesh, byte for byte, so nodes still pin azula's host key and
      # authenticate with the registry-generated, forwarding-only keys. The
      # hostname resolves to raishan on and off the mesh, so every node
      # enrolled from now on takes the same path.
      config.services.nginx.streamConfig = ''
        server {
          listen 2222;
          listen [::]:2222;
          proxy_pass azula.fort.gisi.network:22;
          proxy_connect_timeout 10s;
          # Tunnels idle between agent calls; ssh keepalives run well inside this.
          proxy_timeout 24h;
        }
      '';
      config.networking.firewall.allowedTCPPorts = [ 2222 ];
    };
}
