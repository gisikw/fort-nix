rec {
  hostName = "ratched";
  device = "d62dc783-93c7-d046-aff8-a8595ffcce8e";

  roles = [ ];

  apps = [
    {
      name = "flatnotes";
      subdomain = "exocortex";
      dataDir = "/home/dev/Projects/exocortex/notes";
      dataUser = "dev";
      dataGroup = "users";
    }
    "vdirsyncer-auth"
    "radicale"
    "apple-dist"
    "conduit"
    "temporal"
    "excalidraw"
    "cdn"
  ];

  overlays = {
    knockout = {
      package = "infra/knockout";
      config.port = "19876";
      expose = {
        subdomain = "ko";
        port = 19876;
        visibility = "public";
        sso = { mode = "gatekeeper"; vpnBypass = true; };
      };
    };
    headjack = {
      package = "infra/headjack";
    };
    litmus = {
      package = "infra/litmus";
      config.port = "8700";
      expose = {
        port = 8700;
        visibility = "public";
        sso = { mode = "gatekeeper"; vpnBypass = true; };
      };
    };
    cupola = {
      package = "infra/cupola";
      config = {
        port = "4001";
      };
      secrets = {
        envFile = ./cupola-env.sops;
      };
      expose = {
        port = 4001;
        visibility = "public";
        sso = { mode = "gatekeeper"; vpnBypass = true; localBypass = true; };
      };
    };
    cranium = {
      package = "infra/cranium";
      config = {
        port = "4100";
      };
      secrets = {
        envFile = ./cranium-env.sops;
      };
      expose = {
        port = 4100;
        visibility = "public";
        sso = { mode = "token"; vpnBypass = true; };
      };
      # health = {
      #   type = "http";
      #   endpoint = "http://127.0.0.1:4100/health";
      #   interval = 5;
      #   grace = 10;
      #   stabilize = 15;
      # };
    };
    discovery-zone = {
      package = "infra/discovery-zone";
      config.port = "9878";
      secrets = {
        envFile = ./discovery-zone-env.sops;
      };
      expose = {
        subdomain = "dz";
        port = 9878;
        visibility = "public";
        sso = { mode = "oidc"; vpnBypass = true; };
      };
    };
  };

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
      config.fort.host = {
        inherit roles apps aspects;
      };

      config.systemd.tmpfiles.rules = [
        "d /home/dev/Projects/exocortex 0755 dev users -"
        # notes subdir owned by flatnotes app via dataUser/dataGroup params
      ];
    };
}
