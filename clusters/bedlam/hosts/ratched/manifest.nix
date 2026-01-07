rec {
  hostName = "ratched";
  device = "d62dc783-93c7-d046-aff8-a8595ffcce8e";

  roles = [ ];

  apps = [
    {
      name = "silverbullet";
      subdomain = "exocortex";
      dataDir = "/home/dev/Projects/exocortex";
    }
  ];

  aspects = [
    "mesh"
    "observable"
    {
      name = "dev-sandbox";
      accessKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGBsPj4lG8wP2gfgU5akZ05GrMy55syzvI0MEpiNFQ8t dev-sandbox-ssh"
      ];
    }
    "gitops"
  ];

  module =
    { config, pkgs, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };

      # Add dev user to silverbullet group for shared file access
      config.users.users.dev.extraGroups = [ "silverbullet" ];

      # Set up exocortex directory with proper permissions (setgid for group inheritance)
      config.systemd.tmpfiles.rules = [
        "d /home/dev/Projects/exocortex 2775 dev silverbullet -"
      ];

      # One-time ACL setup service - ensures default ACLs for new files
      config.systemd.services.exocortex-acl-setup = {
        description = "Set default ACLs on exocortex directory";
        wantedBy = [ "multi-user.target" ];
        before = [ "silverbullet.service" ];
        path = [ pkgs.acl ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          # Ensure directory exists with correct ownership
          mkdir -p /home/dev/Projects/exocortex
          chown dev:silverbullet /home/dev/Projects/exocortex
          chmod 2775 /home/dev/Projects/exocortex

          # Allow silverbullet to traverse parent directories (execute only, no read)
          # Must also set mask to allow execute, otherwise effective perms are ---
          setfacl -m u:silverbullet:x,m::x /home/dev
          setfacl -m u:silverbullet:x,m::x /home/dev/Projects

          # Set default ACLs - new files inherit group write permission
          setfacl -R -d -m g:silverbullet:rwX /home/dev/Projects/exocortex
          setfacl -R -m g:silverbullet:rwX /home/dev/Projects/exocortex
        '';
      };
    };
}
