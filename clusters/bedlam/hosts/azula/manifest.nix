rec {
  hostName = "azula";
  device = "166401ec-95f9-6543-854d-a8595f97cd63";

  roles = [ ];

  apps = [
    {
      name = "familiar-instance";
      instanceDir = "/var/lib/kestrel";
      user = "familiar";
      group = "users";
      home = "/home/familiar";
      trackedName = "familiar";
      serviceName = "familiar-instance";
    }
  ];

  overlays = {
    tiamat-router = {
      package = "infra/tiamat-router";
      config = {
        port = "8901";
        configPath = "/var/lib/tiamat-router/bootstrap.json";
      };
      expose = {
        subdomain = "router";
        port = 8901;
        visibility = "public";
        maxBodySize = "100m";
      };
      # Tiamat Router authenticates API clients itself. Do not add identity
      # SSO or copy lordhenry's deprecated legacy Tiamat overlay.
    };
  };

  aspects = [
    "observable"
    "agent-debug"
    "couchdb"
  ];

  module =
    { config, pkgs, ... }:
    let
      # Workers resolve `pi` from PATH; the golem flake's wrapper only pins
      # tmux/git/bash, so the harness CLI rides in via the unit's path.
      pi-coding-agent = import ../../../../pkgs/pi-coding-agent { inherit pkgs; };
      domain = config.fort.cluster.settings.domain;
      familiarHome = "/home/familiar";
      kestrelDir = "/var/lib/kestrel";
      familiarGitTokenPath = "/var/lib/fort-git/familiar-token";
      familiarGitTokenHandler = pkgs.writeShellScript "familiar-git-token-handler" ''
        set -euo pipefail
        ${pkgs.coreutils}/bin/mkdir -p /var/lib/fort-git
        tmp=$(${pkgs.coreutils}/bin/mktemp /var/lib/fort-git/.familiar-token.XXXXXX)
        trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
        ${pkgs.jq}/bin/jq -er '.token' > "$tmp"
        ${pkgs.coreutils}/bin/chown familiar:users "$tmp"
        ${pkgs.coreutils}/bin/chmod 0600 "$tmp"
        ${pkgs.coreutils}/bin/mv -f "$tmp" ${familiarGitTokenPath}
        trap - EXIT
      '';
      familiarGitCredentialHelper = pkgs.writeShellScript "familiar-git-credential-helper" ''
        case "''${1:-}" in
          get)
            [ -r ${familiarGitTokenPath} ] && [ -s ${familiarGitTokenPath} ] || exit 0
            echo "username=forge-admin"
            echo "password=$(${pkgs.coreutils}/bin/cat ${familiarGitTokenPath})"
            ;;
        esac
      '';
      stuffForFamiliar = pkgs.writeShellScript "stuff-for-familiar" ''
        export STUFF_URL="''${STUFF_URL:-http://127.0.0.1:7847}"
        export STUFF_TOKEN_FILE="''${STUFF_TOKEN_FILE:-/run/secrets/stuff-api-token}"
        exec /nix/var/nix/profiles/fort-tracked-stuff/profile/bin/stuff "$@"
      '';
      golemdConfig = pkgs.writeText "golemd-azula.toml" ''
        name = "azula"
        clone_enabled = true
        api_bearer_tokens = []

        [providers.llama]
        base_url = "https://llama.gisi.network/v1"
        api_key_env = ""

        # Router-backed providers are registered dynamically inside each
        # isolated pi worker. Golem owns no upstream OAuth state.
        [providers.tiamat-anthropic-claude-code-personal]
        kind = "tiamat"

        [providers.tiamat-responses-codex-personal]
        kind = "tiamat"

        [providers.tiamat-openai-llama-frankenstein]
        kind = "tiamat"

        [harnesses.pi]
        models = [
          "tiamat-anthropic-claude-code-personal/claude-fable-5",
          "tiamat-anthropic-claude-code-personal/claude-haiku-4-5-20251001",
          "tiamat-anthropic-claude-code-personal/claude-opus-4-5-20251101",
          "tiamat-anthropic-claude-code-personal/claude-opus-4-6",
          "tiamat-anthropic-claude-code-personal/claude-opus-4-7",
          "tiamat-anthropic-claude-code-personal/claude-opus-4-8",
          "tiamat-anthropic-claude-code-personal/claude-opus-5",
          "tiamat-anthropic-claude-code-personal/claude-sonnet-4-5-20250929",
          "tiamat-anthropic-claude-code-personal/claude-sonnet-4-6",
          "tiamat-anthropic-claude-code-personal/claude-sonnet-5",
          "tiamat-responses-codex-personal/codex-auto-review",
          "tiamat-responses-codex-personal/gpt-5.4",
          "tiamat-responses-codex-personal/gpt-5.4-mini",
          "tiamat-responses-codex-personal/gpt-5.5",
          "tiamat-responses-codex-personal/gpt-5.6-luna",
          "tiamat-responses-codex-personal/gpt-5.6-sol",
          "tiamat-responses-codex-personal/gpt-5.6-terra",
          "tiamat-responses-codex-personal/gpt-reserve",
          "tiamat-openai-llama-frankenstein/Qwen3.8-27B-UD-Q4_K_XL",
          # Keep the direct path as a fallback while Router wiring settles.
          "llama/Qwen3.8-27B-UD-Q4_K_XL",
        ]

        [harnesses.fake]
        models = []

        [projects.scratch]
        path = "/var/lib/golem/projects/scratch"
        description = "Azula scratch repository"

        [attach_ssh]
        port = 0
      '';
    in
    {
      config.fort.host = { inherit roles apps aspects; };

      # Manual Familiar rewrite test deployment. Keep the account declarative so
      # GitOps activation does not remove the long-running Presence/supervisor
      # owner created during pre-cutover testing.
      config.users.users.familiar = {
        isNormalUser = true;
        home = familiarHome;
        createHome = true;
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = [ config.fort.cluster.settings.principals.admin.publicKey ];
      };

      config.users.groups.tiamat-router = { };
      config.users.users.tiamat-router = {
        isSystemUser = true;
        group = "tiamat-router";
        description = "Tiamat Router service user";
        home = "/var/lib/tiamat-router";
        createHome = true;
      };

      config.fort.cluster.services = [
        {
          name = "familiar";
          port = 1692;
          visibility = "public";
          sso = {
            mode = "identity";
            groups = [
              "admin"
              "infra"
            ];
          };
        }
      ];

      # Kestrel is the private, durable Familiar instance—not a developer
      # checkout. Fort owns its location and permissions; the one-time cutover
      # populates the directory before starting familiar-instance.
      config.systemd.tmpfiles.rules = [
        "d ${familiarHome}/.ssh 0700 familiar users -"
        "d ${familiarHome}/.config 0700 familiar users -"
        "d ${familiarHome}/.config/gh 0700 familiar users -"
        "d ${kestrelDir} 0700 familiar users -"
        # Presence already carries this directory at the front of PATH. A
        # stable link makes the dynamic tracked profile available immediately
        # without restarting the resident conversation.
        "d ${kestrelDir}/state/pi/bin 0700 familiar users -"
        "L+ ${kestrelDir}/state/pi/bin/stuff - - - - ${stuffForFamiliar}"
      ];

      # Reuse the established developer SSH identity for outbound work from
      # Kestrel without importing the rest of dev-sandbox.
      config.sops.secrets.familiar-ssh-key = {
        sopsFile = ../../../../aspects/dev-sandbox/ssh-key.sops;
        format = "binary";
        path = "${familiarHome}/.ssh/id_ed25519";
        owner = "familiar";
        group = "users";
        mode = "0600";
      };
      config.system.activationScripts.familiar-ssh-pubkey = ''
        echo "${config.fort.cluster.settings.principals.dev-sandbox.sshKey}" > ${familiarHome}/.ssh/id_ed25519.pub
        chown familiar:users ${familiarHome}/.ssh/id_ed25519.pub
        chmod 0644 ${familiarHome}/.ssh/id_ed25519.pub
      '';

      # Request a dedicated RW Forgejo token for Kestrel's archive pushes.
      # The helper is host-global but only familiar can read this token.
      config.fort.host.needs.git-token.familiar = {
        from = "drhorrible";
        request = {
          access = "rw";
        };
        handler = familiarGitTokenHandler;
      };
      config.environment.etc."familiar-git-credential-helper".source = familiarGitCredentialHelper;
      config.programs.git = {
        enable = true;
        config = {
          user.name = "Kevin Gisi";
          user.email = "kevin@kevingisi.com";
          init.defaultBranch = "main";
          credential."https://git.${domain}".helper = "/etc/familiar-git-credential-helper";
          safe.directory = kestrelDir;
        };
      };

      # Shared credential used by the Familiar rewrite stack to authenticate to
      # tiamat-router without placing the token in the Nix store.
      config.sops.secrets.tiamat-router-token = {
        sopsFile = ../../../../aspects/dev-sandbox/tiamat-router-token.sops;
        format = "binary";
        path = "/run/secrets/tiamat-router-token";
        owner = "familiar";
        group = "users";
        mode = "0400";
      };

      # The Router needs the same bootstrap token without gaining access to
      # Familiar's client-owned secret path. SOPS may materialize one payload
      # at two paths with distinct ownership.
      config.sops.secrets.tiamat-router-bootstrap-token = {
        sopsFile = ../../../../aspects/dev-sandbox/tiamat-router-token.sops;
        format = "binary";
        owner = "tiamat-router";
        group = "tiamat-router";
        mode = "0400";
      };

      # Runtime assembly keeps the bearer token out of the Nix store. The
      # overlay unit requires this oneshot even when overlay-manager creates or
      # restarts the service after boot.
      config.systemd.services.tiamat-router-bootstrap-provision = {
        description = "Provision tiamat-router bootstrap configuration";
        wantedBy = [ "multi-user.target" ];
        before = [ "overlay-tiamat-router.service" ];
        after = [ "sops-nix.service" ];
        restartTriggers = [ config.sops.secrets.tiamat-router-bootstrap-token.sopsFile ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail
          token="$(${pkgs.coreutils}/bin/tr -d '\n' < ${config.sops.secrets.tiamat-router-bootstrap-token.path})"
          test -n "$token"
          umask 077
          ${pkgs.jq}/bin/jq -n --arg token "$token" \
            '{clients: [{id: "dev-sandbox", token: $token}], providers: []}' \
            > /var/lib/tiamat-router/bootstrap.json.tmp
          ${pkgs.coreutils}/bin/install -o tiamat-router -g tiamat-router -m 0400 \
            /var/lib/tiamat-router/bootstrap.json.tmp /var/lib/tiamat-router/bootstrap.json
          ${pkgs.coreutils}/bin/rm -f /var/lib/tiamat-router/bootstrap.json.tmp
        '';
      };

      config.systemd.units."overlay-tiamat-router.service" = {
        overrideStrategy = "asDropin";
        text = ''
          [Unit]
          Requires=tiamat-router-bootstrap-provision.service
          After=tiamat-router-bootstrap-provision.service
        '';
      };

      # Familiar code tree: tracked from main, tree-only (exec = null — the
      # runtime is familiar.sh + source tree, not a profile binary). Building
      # #familiar-server is the validation gate: the tree only advances when
      # the server flake builds and tests green. The familiar-instance app runs
      # the private instance against this tree and is bounced via restartUnits
      # after each update; independently owned Presence is not.
      config.fort.tracked.familiar = {
        repo = "gisikw/familiar";
        branch = "main";
        flakeAttr = "familiar-server";
        autoUpdate = true;
        pollInterval = "15m";
        exec = null;
        user = "familiar";
        group = "users";
        restartUnits = [ "familiar-instance.service" ];
      };

      # golemd is runtime-deployed: fort.tracked builds gisikw/golem's flake
      # on-host and flips a profile; nix evaluation cadence stays decoupled
      # from app deployment cadence. See common/fort/tracked.nix.
      config.fort.tracked.golemd = {
        repo = "gisikw/golem";
        flakeAttr = "full";
        autoUpdate = true;
        pollInterval = "15m";
        # --linger 1h: retained-session policy is explicit and configurable
        # by editing this tracked runner config (default would also be 1h, but
        # making it explicit prevents surprises if golemd's default changes).
        exec = "golemd --config ${golemdConfig} --state /var/lib/golem --listen 127.0.0.1:9920 --linger 1h";
        addToPath = true;
        unit = {
          description = "Golem delegated-agent daemon";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          path = [
            pkgs.git
            pkgs.tmux
            pkgs.bashInteractive
            pi-coding-agent
          ];
          # golemd runs as familiar:users so that the Familiar renderer/viewer
          # (also familiar:users) can reach /var/lib/golem/tmux.sock (0600,
          # owner familiar) and golemd.sock without any supplemental group or
          # ACL machinery. systemd's StateDirectory= handling automatically
          # chowns /var/lib/golem to familiar on the first activation after
          # this change; no explicit migration step is required. The former
          # golem system user/group declarations are removed because nothing
          # else depended on them.
          preStart = ''
            set -euo pipefail
            scratch=/var/lib/golem/projects/scratch
            marker="$scratch/.golem-bootstrap-v1"
            mkdir -p "$scratch"
            if [ ! -e "$marker" ]; then
              if ! git -C "$scratch" rev-parse --git-dir >/dev/null 2>&1; then
                git -C "$scratch" init
              fi
              if ! git -C "$scratch" rev-parse --verify HEAD >/dev/null 2>&1; then
                git -C "$scratch" \
                  -c user.name='Golem Bootstrap' \
                  -c user.email='golem@azula' \
                  commit --allow-empty -m 'Initialize Golem scratch project'
              fi
              touch "$marker"
            fi
          '';
          serviceConfig = {
            User = "familiar";
            Group = "users";
            StateDirectory = "golem";
            # 0700: only familiar (the service user) needs direct filesystem
            # access; the socket inside is 0600 and also owner=familiar, so
            # the Familiar renderer (same UID) reaches it without relaxing
            # the directory.
            StateDirectoryMode = "0700";
            Restart = "on-failure";
          };
          environment = {
            # Explicitly pin HOME so golemd's UserHomeDir()-derived defaults
            # (allowed-cwd-roots, artifact paths) resolve to the familiar home
            # directory rather than relying on systemd PAM/passwd lookup order.
            HOME = "/home/familiar";
            # Belt and braces: golemd pins the private tmux server's
            # default-shell from this variable.
            GOLEM_INTERACTIVE_SHELL = "${pkgs.bashInteractive}/bin/bash";
            GOLEM_TIAMAT_URL = "https://router.gisi.network";
            GOLEM_TIAMAT_TOKEN_FILE = "/run/secrets/tiamat-router-token";
          };
        };
      };

      # Stuff is a small CouchDB-backed Item/Note gateway. Its binary follows
      # the public repository independently of host evaluation, while the
      # runner itself remains declarative and least-privileged.
      config.users.groups.stuff = { };
      config.users.users.stuff = {
        isSystemUser = true;
        group = "stuff";
      };

      config.sops.secrets.stuff-api-token = {
        sopsFile = ./stuff-api-token.sops;
        format = "binary";
        # Familiar is the local CLI principal. The service receives this same
        # file through systemd's private credential directory below.
        owner = "familiar";
        group = "users";
        mode = "0400";
        restartUnits = [ "stuff.service" ];
      };

      config.fort.tracked.stuff = {
        repo = "gisikw/stuff";
        flakeAttr = "default";
        autoUpdate = true;
        pollInterval = "15m";
        exec = "stuff serve";
        # Adds the dynamic profile to login-shell PATH, including for the
        # familiar account, without pinning the binary into the host closure.
        addToPath = true;
        expose = {
          subdomain = "stuff";
          port = 7847;
          visibility = "public";
          sso = {
            mode = "identity";
            groups = [ "admin" ];
          };
          health.endpoint = "/health";
        };
        unit = {
          description = "Stuff Item and Note service";
          after = [
            "network-online.target"
            "couchdb.service"
            "sops-nix.service"
          ];
          wants = [ "network-online.target" ];
          requires = [ "couchdb.service" ];
          preStart = ''
            set -euo pipefail
            password="$(${pkgs.gawk}/bin/awk -F '[[:space:]]*=[[:space:]]*' \
              '$1 == "stuff" { print $2; exit }' \
              "$CREDENTIALS_DIRECTORY/couchdb-admin")"
            if [ -z "$password" ]; then
              echo "Stuff: CouchDB credential did not contain the expected user" >&2
              exit 1
            fi
            umask 077
            ${pkgs.coreutils}/bin/printf '%s' "$password" > /run/stuff/couchdb-password
          '';
          environment = {
            STUFF_LISTEN = "127.0.0.1:7847";
            STUFF_COUCH_URL = "http://127.0.0.1:5984";
            STUFF_COUCH_DB = "stuff";
            STUFF_COUCH_USER = "stuff";
            STUFF_COUCH_PASSWORD_FILE = "/run/stuff/couchdb-password";
            STUFF_TOKEN_FILE = "/run/credentials/stuff.service/api-token";
          };
          serviceConfig = {
            User = "stuff";
            Group = "stuff";
            RuntimeDirectory = "stuff";
            RuntimeDirectoryMode = "0700";
            LoadCredential = [
              "couchdb-admin:${config.sops.secrets.couchdb-admin.path}"
              "api-token:${config.sops.secrets.stuff-api-token.path}"
            ];
            Restart = "on-failure";
            RestartSec = "5s";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            CapabilityBoundingSet = "";
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
          };
        };
      };

      config.environment.variables = {
        GOLEM_ENDPOINT = "http://127.0.0.1:9920";
        STUFF_URL = "http://127.0.0.1:7847";
        STUFF_TOKEN_FILE = config.sops.secrets.stuff-api-token.path;
      };

      # Office captive-portal survival kit. Azula may need to register on
      # unfamiliar networks before it can fetch anything else, so keep both a
      # graphical browser path and text-mode/debug tools available locally.
      config.services.xserver.enable = true;
      config.services.xserver.displayManager.lightdm.enable = true;
      config.services.xserver.desktopManager.xfce.enable = true;

      config.environment.systemPackages = with pkgs; [
        firefox
        w3m
        lynx
        curl
        wget
        dnsutils
        openssl
        xterm

        # Minimal operator/development baseline for Kestrel. Project-specific
        # compilers and runtimes remain the responsibility of nix develop.
        git
        gh
        openssh
        rsync
        ripgrep
        fd
      ];
    };
}
