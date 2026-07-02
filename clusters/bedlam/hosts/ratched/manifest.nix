rec {
  hostName = "ratched";
  device = "d62dc783-93c7-d046-aff8-a8595ffcce8e";

  roles = [ ];

  apps = [
    "vdirsyncer-auth"
    "radicale"
    "apple-dist"
    "conduit"
    "cdn"
    {
      name = "sse-probe";
      mode = "monitor";
      targets = [
        "joker=http://joker.fort.gisi.network:9400/events"
        "raishan=http://raishan.fort.gisi.network:9400/events"
      ];
    }
  ];

  overlays = {
    knockout = {
      package = "infra/knockout";
      config.port = "19876";
      expose = {
        subdomain = "ko";
        port = 19876;
        visibility = "public";
        sso = { mode = "identity"; groups = [ "admin" "infra" ]; };
      };
    };
    questbook = {
      package = "infra/questbook";
      config.port = "19877";
      expose = {
        subdomain = "qb";
        port = 19877;
        visibility = "public";
        sso = { mode = "identity"; groups = [ "admin" "infra" ]; };
      };
    };
    headjack = {
      package = "infra/headjack";
    };
    muse = {
      package = "infra/muse";
    };
    phylactery = {
      package = "infra/phylactery";
    };
    litmus = {
      package = "infra/litmus";
      config.port = "8700";
      expose = {
        port = 8700;
        visibility = "public";
        sso = { mode = "identity"; groups = [ "admin" ]; };
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
        sso = { mode = "identity"; groups = [ "admin" "infra" ]; };
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
    lair = {
      package = "infra/lair";
      config.port = "4002";
      expose = {
        port = 4002;
        visibility = "public";
        sso = { mode = "identity"; groups = [ "admin" ]; };
      };
    };
    kobold = {
      package = "infra/kobold";
      config.port = "4200";
      # Inference nodes call Tiamat on lordhenry (tiamat.turn.request.v1).
      config.tiamatBaseUrl = "https://tiamat.gisi.network";
      # Default profile for inference nodes: non-persona, local, free.
      # Nodes needing frontier quality override via per-node config.profile.
      config.inferenceProfile = "qwen-local";
      # VPN-only by default (no visibility key): kobold's HTTP port is
      # remote code execution by design and must never be public. No sso.
      expose = {
        subdomain = "kobold";
        port = 4200;
      };
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
        sso = { mode = "identity"; groups = [ "admin" ]; };
      };
    };
  };

  aspects = [
    "mesh"
    "observable"
    "backup-client"
    {
      name = "dev-sandbox";
      accessKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGBsPj4lG8wP2gfgU5akZ05GrMy55syzvI0MEpiNFQ8t dev-sandbox-ssh"
      ];
    }
    "gitops"
  ];

  module =
    { config, pkgs, lib, ... }:
    {
      config.fort.host = {
        inherit roles apps aspects;
      };

      # PostgreSQL for overlays (cranium, kobold). Trust auth on localhost — no
      # password complexity needed on a single-user dev sandbox.
      config.services.postgresql.enable = true;
      config.services.postgresql.authentication = lib.mkForce ''
        local   all             all                                     trust
        host    all             all             127.0.0.1/32            trust
        host    all             all             ::1/128                 trust
      '';
      config.services.postgresql.ensureDatabases = [ "kobold" ];
      config.services.postgresql.ensureUsers = [
        {
          name = "kobold";
          ensureDBOwnership = true;
        }
      ];

      config.environment.systemPackages = [ pkgs.inotify-tools ];

      config.systemd.tmpfiles.rules = [
        "d /home/dev/Projects/exocortex 0755 dev users -"
        # kobold overlay working directory: systemd chdirs into it before
        # exec, so the service cannot create it itself (it creates its
        # artifact/work roots underneath on boot).
        "d /home/dev/.local/state/kobold 0755 dev users -"
      ];
    };
}
