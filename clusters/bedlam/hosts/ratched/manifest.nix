rec {
  hostName = "ratched";
  device = "d62dc783-93c7-d046-aff8-a8595ffcce8e";

  roles = [ ];

  apps = [
    "vdirsyncer-auth"
    "radicale"
    "conduit"
    "cdn"
    "capstone"
    "vault"
  ];

  overlays = {
    knockout = {
      package = "infra/knockout";
      config = {
        port = "19876";
        # Knockout -> Questbook cutover (serve side): route the remote/HTTP path
        # (ko serve -> Punchlist et al.) through the QQL shim, keep the legacy
        # store read-only, and log every shim invocation. KO_SHIM_LOG is the
        # cutover's vital sign — when it goes quiet, migration is done.
        koQql = "1";
        koQqlUrl = "http://127.0.0.1:19877";
        koQqlMapping = "/etc/knockout/qql-mapping.yaml";
        koReadonly = "1";
        koShimLog = "/var/lib/knockout/shim-usage.jsonl";
      };
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
        grottoUrl = "https://grotto.gisi.network";
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
    scholia = {
      package = "infra/scholia";
      # Epistemic ledger + marginalia service (v0 shadow mode). Mesh-internal:
      # HTTP is canonical but consumers are local (cranium, CLI, kobold jobs).
      # No expose block — localhost only until shadow-mode gates pass.
      config.port = "9879";
    };
    # Coffer client daemon: leases secrets from drhorrible's coffer-server and
    # serves them to same-host workloads over a peer-credential unix socket
    # (SO_PEERCRED uid -> workload -> grant, AMENDMENT 1). Users, config TOML,
    # trust anchor, and the root-side client-cert mint live in the module
    # block below. cofferd restarts on-failure until the minted cert exists;
    # the grant is filed and delivered by cofferd itself (request → approve →
    # deliver) — convergence, not orchestration.
    coffer = {
      package = "infra/coffer";
      config.role = "daemon";
    };
    spyglass = {
      package = "infra/spyglass";
      # Outbound discovery engine: serve unit here; the ingest/score/wiki
      # cycle runs via the spyglass-cycle timer in the module block below.
      # Mesh-internal for now — Lair will consume it via relay; no expose.
      config.port = "8377";
    };
    discovery-zone = {
      package = "infra/discovery-zone";
      # Uses knockout's ko binary from /run/overlays/bin — declared so
      # activation orders knockout first instead of relying on PATH luck
      # (q-1e0a32ed).
      dependsOn = [ "knockout" ];
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

      # Grotto shared-write group: agents and dev user can read/write
      # materialized trees once plane-2 materialize mappings are configured.
      config.users.groups.grotto = { };
      config.users.users.dev.extraGroups = [
        "grotto"
        # coffer: lets dev connect to the cofferd socket for verification. The
        # socket mode is a coarse gate; the peer-credential workload mapping is
        # the real boundary (dev maps to no workload and is denied).
        "coffer"
      ];
      config.environment.systemPackages = [ pkgs.inotify-tools ];

      # ---- Coffer client daemon (cofferd) ----
      # The cofferd overlay unit runs unprivileged as coffer:coffer. lair is
      # pinned to uid 494 so the [[workload]] peer-credential mapping below is
      # stable across rebuilds; lair joins the coffer group to reach the
      # socket (0660 coffer:coffer).
      config.users.users.coffer = {
        isSystemUser = true;
        group = "coffer";
        home = "/var/lib/cofferd";
      };
      config.users.groups.coffer = { };
      config.users.users.lair = {
        isSystemUser = true;
        uid = 494;
        group = "lair";
        extraGroups = [ "coffer" ];
      };
      config.users.groups.lair = { };

      # trust_anchors is the committed coffer-server PUBLIC cert
      # (clusters/bedlam/coffer-server.crt) — public key material, not a
      # secret; the private key never leaves drhorrible and the pinned client
      # key is the real security boundary. Rotation = re-mint on drhorrible,
      # one commit here, every consumer host converges via gitops.
      config.environment.etc."cofferd/server.crt".source = ../../coffer-server.crt;
      # Config, not Coffer state: client.crt/client.key are minted on-box by
      # the oneshot below; lair's grant is requested by cofferd (grant_shape
      # below) and delivered by its poll loop once approved in coffer-web —
      # the scp/hand-placed workflow is dead (see coffer OPERATIONS.md).
      config.environment.etc."cofferd/config.toml".text = ''
        server = "https://drhorrible.fort.gisi.network:7787"
        socket = "/run/cofferd/coffer.sock"
        tls_cert = "/var/lib/cofferd/client.crt"
        tls_key = "/var/lib/cofferd/client.key"
        trust_anchors = "/etc/cofferd/server.crt"

        [[workload]]
        name = "lair"
        grant_file = "/var/lib/cofferd/grants/lair.grant"
        uid = 494
        prewarm = [
          { namespace = "fort/openai", name = "cred" },
          # anthropic cred unblocks lair's usage-monitoring wiring; needs
          # fort/anthropic/cred created + the widened grant approved in
          # coffer-web (cofferd re-files the request from grant_shape).
          { namespace = "fort/anthropic", name = "cred" },
        ]
        # grant_shape makes cofferd file the grant request itself; secrets
        # default to prewarm, verbs to ["read"], ttl to 720h.
        grant_shape = { }
      '';

      # Root-side client-cert mint: wraps ratched's ed25519 ssh host key in a
      # self-signed client cert (SPKI == host key, so the server's TOFU pin
      # ties to host identity; idempotent — re-mint keeps the same pin). The
      # overlay unit cannot do this itself: reading the host key is root-only.
      # The binary is resolved from the overlay unit's ExecStart, NOT from
      # /run/overlays/bin: that symlink only appears once the overlay passes
      # health, and health cannot pass without this cert — keying on the
      # symlink deadlocks first deploy. Falls back to the symlink for the
      # steady state where it does exist.
      config.systemd.services.cofferd-mint-client-cert = {
        description = "Mint cofferd client certificate from the host ssh key";
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.coreutils pkgs.systemd pkgs.gnugrep ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          bin=""
          for _ in $(seq 1 120); do
            bin=$(systemctl show -p ExecStart overlay-coffer-cofferd.service 2>/dev/null \
              | grep -o '/nix/store/[^ ;]*/bin/cofferd' | head -1 || true)
            if [ -z "$bin" ] && [ -x /run/overlays/bin/cofferd ]; then
              bin=/run/overlays/bin/cofferd
            fi
            [ -n "$bin" ] && [ -x "$bin" ] && break
            bin=""
            sleep 5
          done
          [ -n "$bin" ] || { echo "cofferd binary never appeared" >&2; exit 1; }
          "$bin" --mint-client-cert \
            --ssh-key /etc/ssh/ssh_host_ed25519_key \
            --out-cert /var/lib/cofferd/client.crt \
            --out-key /var/lib/cofferd/client.key \
            --san ratched
          chown coffer:coffer /var/lib/cofferd/client.crt /var/lib/cofferd/client.key
        '';
      };

      # Spyglass cycle: ingest → score → wiki on a timer. Runs as dev from
      # the repo working copy (spyglass resolves config/TASTE.md/wiki/data
      # relative to cwd; TASTE.md edits and wiki accretion are part of the
      # product loop). Binary via /run/overlays/bin — present once the
      # spyglass overlay passes health; timer's OnBootSec outlives that.
      # Scoring calls Ollama on lordhenry; feed failures are tolerated
      # per-source (exit 0), so on-failure retry loops are unnecessary.
      config.systemd.services.spyglass-cycle = {
        description = "Spyglass discovery cycle (ingest, score, wiki)";
        serviceConfig = {
          Type = "oneshot";
          User = "dev";
          Group = "users";
          WorkingDirectory = "/home/dev/Projects/spyglass";
          Environment = [ "HOME=/home/dev" ];
          ExecStart = "/run/overlays/bin/spyglass cycle";
        };
      };

      config.systemd.timers.spyglass-cycle = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "10m";
          OnUnitActiveSec = "2h";
        };
      };

      # Gee bridge publisher: the SINGLE writer to the gee belief ledger.
      # `gee eval` appends mechanical status transitions on every run, so
      # exactly one caller may invoke it; cranium only ever reads the
      # published artifact (see cranium docs/gee-belief-injection.md).
      # Publishes atomically (write temp + rename) every 15 minutes. The
      # gee binary is dev-managed at ~/.local/bin/gee (built from
      # ~/Projects/gee), same as the other dev-sandbox tools.
      config.systemd.services.gee-bridge-publisher = {
        description = "Publish gee eval --bridge artifact for cranium belief injection";
        serviceConfig = {
          Type = "oneshot";
          User = "dev";
          Group = "users";
          Environment = [ "HOME=/home/dev" ];
          ExecStart = pkgs.writeShellScript "gee-bridge-publish" ''
            set -euo pipefail
            out=/home/dev/.local/state/gee/bridge.txt
            mkdir -p "$(dirname "$out")"
            tmp="$out.tmp.$$"
            trap 'rm -f "$tmp"' EXIT
            /home/dev/.local/bin/gee eval --bridge > "$tmp"
            mv "$tmp" "$out"
          '';
        };
      };

      config.systemd.timers.gee-bridge-publisher = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitActiveSec = "15m";
        };
      };

      config.systemd.tmpfiles.rules = [
        "d /home/dev/Projects/exocortex 0755 dev users -"
        # kobold overlay working directory: systemd chdirs into it before
        # exec, so the service cannot create it itself (it creates its
        # artifact/work roots underneath on boot).
        "d /home/dev/.local/state/kobold 0755 dev users -"
        # knockout overlay QQL-shim usage log dir (KO_SHIM_LOG). Owned by dev,
        # the user the knockout overlay runs as. Persisted under /var/lib.
        "d /var/lib/knockout 0755 dev users -"
        # cofferd state (client cert/key, delivered grants) and socket
        # dir. Group coffer traverses; the socket itself is 0660 coffer:coffer.
        "d /var/lib/cofferd 0750 coffer coffer -"
        "d /run/cofferd 0750 coffer coffer -"
        # lair traversal ACL: execute-only on /home/dev (no read/list) so the
        # lair service user can reach the world-readable while-you-slept feed
        # under ~/Projects/hoard without loosening /home/dev's 0700 mode.
        "a+ /home/dev - - - - u:lair:--x"
      ];
    };
}
