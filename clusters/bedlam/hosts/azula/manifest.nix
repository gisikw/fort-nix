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
      # Unfamiliar's shepherd peers into golem capsules through Bun.Terminal,
      # which landed after nixos-25.11's bun (1.3.3). Pin the same 1.3.13
      # release the unfamiliar flake resolves so the unit and the test suite
      # agree on what Bun is. Drop this once nixpkgs carries >= 1.3.13.
      unfamiliarBun = pkgs.bun.overrideAttrs (old: rec {
        version = "1.3.13";
        src = pkgs.fetchurl {
          url = "https://github.com/oven-sh/bun/releases/download/bun-v${version}/bun-linux-x64.zip";
          hash = "sha256-ecB3H6i5LDOq5B4VoODTB+qZ0OLwAxfHHGxTI3p44lo=";
        };
      });
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
          "tiamat-anthropic-claude-code-personal/claude-fable-5-1",
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

      # Hard-hang mitigation (2026-09-04). Three whole-host lock-ups in one
      # evening, each showing ~27 GB free, load < 1, temps < 60 °C on the
      # last Prometheus scrape before going dark — no resource ramp, just
      # gone. Kernel 6.12 is early for this Strix Point APU (HX 470 / 890M);
      # amdgpu already logs a DCN REG_WAIT timeout at every boot. Track the
      # newest kernel on this host only; other hosts keep the default.
      config.boot.kernelPackages = pkgs.linuxPackages_latest;

      # Erase-your-darlings drops the journal with the boot, so a hang leaves
      # no body. Persist it so `journalctl -b -1 -k` can testify next time.
      config.services.journald.storage = "persistent";
      config.environment.persistence."/persist/system".directories = [ "/var/log/journal" ];

      # Manual Familiar rewrite test deployment. Keep the account declarative so
      # GitOps activation does not remove the long-running Presence/supervisor
      # owner created during pre-cutover testing.
      config.users.users.familiar = {
        isNormalUser = true;
        home = familiarHome;
        createHome = true;
        shell = pkgs.bashInteractive;
        # systemd-journal: plain journalctl works without escalation.
        extraGroups = [ "systemd-journal" ];
        openssh.authorizedKeys.keys = [ config.fort.cluster.settings.principals.admin.publicKey ];
      };

      # Familiar operates this host (service state dirs, unit debugging) and
      # has no password, so sudo must not prompt for one.
      config.security.sudo.extraRules = [
        {
          users = [ "familiar" ];
          commands = [
            {
              command = "ALL";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];

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
        # Unfamiliar: the pi-SDK rewrite of Familiar, served from Kevin's
        # development checkout so the morning inspection sees what runs.
        {
          name = "unfamiliar";
          port = 1700;
          visibility = "public";
          sso = {
            mode = "identity";
            groups = [ "admin" ];
          };
        }
        # Static wireframe drafts, served straight out of the checkout in
        # Kevin's home directory (no build step, no unit — just files).
        {
          name = "wireframes";
          staticRoot = "${familiarHome}/Projects/wireframes";
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

      # nginx's unit runs with ProtectHome=true, so the static root has to be
      # bind-mounted into its namespace anyway (same idiom as apps/vault). That
      # also means /home/familiar itself never has to become traversable: the
      # only mode this host relaxes is the wireframes directory (0755 below).
      config.systemd.services.nginx.serviceConfig = {
        ProtectHome = pkgs.lib.mkForce "tmpfs";
        BindReadOnlyPaths = [ "${familiarHome}/Projects/wireframes" ];
      };

      # Serve index.html for directories, with an autoindex fallback for the
      # bare drafts. The generic static location (common/fort/nginx.nix) only
      # emits try_files; extraConfig is types.lines, so this appends.
      config.services.nginx.virtualHosts."wireframes.${domain}".locations."/".extraConfig = ''
        index index.html;
        autoindex on;
      '';

      # Unfamiliar runtime (see ~/Projects/unfamiliar/docs/ARCHITECTURE.md).
      # Runs the checkout in place as familiar with Bun; state under
      # /var/lib/unfamiliar; identity read from Kestrel's stack read-only.
      # Restart to pick up code changes: `sudo systemctl restart unfamiliar`.
      # (state dir tmpfiles rule lives in the shared list below)
      # Kestrel (running as familiar) deploys Unfamiliar by merging to the
      # checkout and restarting the unit. Let that user manage exactly this
      # unit without interactive auth; nothing else.
      config.security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") == "unfamiliar.service" &&
              subject.user == "familiar") {
            return polkit.Result.YES;
          }
        });
      '';

      config.systemd.services.unfamiliar = {
        description = "Unfamiliar — persistent presence on the pi SDK";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "sops-nix.service" "golemd.service" ];
        wants = [ "network-online.target" ];
        # tmux is the client half of shepherd's peer-in terminal: it attaches
        # to golemd's worker sessions at /var/lib/golem/tmux.sock.
        path = with pkgs; [ unfamiliarBun nodejs_22 git bashInteractive coreutils tmux ];
        environment = {
          HOME = familiarHome;
          UNFAMILIAR_CONFIG = "${familiarHome}/Projects/unfamiliar/deploy/azula.toml";
          UNFAMILIAR_ROOT = "${familiarHome}/Projects/unfamiliar";
          GOLEM_ENDPOINT = "http://127.0.0.1:9920";
        };
        serviceConfig = {
          User = "familiar";
          Group = "users";
          WorkingDirectory = "${familiarHome}/Projects/unfamiliar";
          ExecStart = "${unfamiliarBun}/bin/bun run apps/server/src/main.ts";
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };

      # Kestrel is the private, durable Familiar instance—not a developer
      # checkout. Fort owns its location and permissions; the one-time cutover
      # populates the directory before starting familiar-instance.
      config.systemd.tmpfiles.rules = [
        "d /var/lib/unfamiliar 0700 familiar users -"
        "d ${familiarHome}/.ssh 0700 familiar users -"
        "d ${familiarHome}/.config 0700 familiar users -"
        "d ${familiarHome}/.config/gh 0700 familiar users -"
        "d ${kestrelDir} 0700 familiar users -"
        # Presence already carries this directory at the front of PATH. A
        # stable link makes the dynamic tracked profile available immediately
        # without restarting the resident conversation.
        "d ${kestrelDir}/state/pi/bin 0700 familiar users -"
        "L+ ${kestrelDir}/state/pi/bin/stuff - - - - ${stuffForFamiliar}"
        # Wireframes static root: exists before nginx's BindReadOnlyPaths
        # resolves it, and world-readable so the nginx user can read it.
        "d ${familiarHome}/Projects - familiar users -"
        "d ${familiarHome}/Projects/wireframes 0755 familiar users -"
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
      # Do not autostart the display manager: this is a headless box that has
      # hard-hung on amdgpu (DCN REG_WAIT timeouts at every boot on 6.12), and
      # the graphical session is only needed for captive portals. NixOS pulls
      # display-manager in via graphical.target's own Wants=, so forcing the
      # service's wantedBy does nothing; boot to multi-user instead. When a
      # portal needs it: `sudo systemctl start display-manager` (or
      # `systemctl isolate graphical.target`); it will not return after reboot.
      config.systemd.defaultUnit = pkgs.lib.mkForce "multi-user.target";

      # Carrier watchdog for the Aquantia (atlantic) NIC. 2026-09-04: five
      # "freezes" turned out to be eno1 reporting link 1000 -> 0 and never
      # renegotiating; the host itself ran fine for minutes until power-cycled.
      # Nothing in the stack bounces a NIC that merely looks unplugged, so this
      # does: after LIMIT seconds without carrier, down/up the link; if still
      # dead, remove and rescan the PCI device to reinitialise the firmware.
      config.systemd.services.eno1-carrier-watchdog = {
        description = "Bounce eno1 when carrier stays lost";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = with pkgs; [ coreutils iproute2 ];
        serviceConfig = {
          Restart = "always";
          RestartSec = "10s";
        };
        # NB: NixOS runs `script` under `sh -e`. `ip link set up` exits 2 when the
        # atlantic firmware is hung ("Boot code hanged"), which used to abort the
        # script before the rescan ever ran -- three incidents, zero rescans.
        script = ''
          set -u +e
          IF=eno1
          LIMIT=20
          lost=0
          while :; do
            if [ "$(cat /sys/class/net/$IF/carrier 2>/dev/null || echo 0)" = "1" ]; then
              lost=0
            else
              lost=$((lost + 5))
              if [ "$lost" -ge "$LIMIT" ]; then
                echo "$IF: no carrier for ''${lost}s, bouncing link"
                pci=$(basename "$(readlink -f /sys/class/net/$IF/device)")
                ip link set "$IF" down; sleep 2
                if ip link set "$IF" up; then
                  sleep 10
                else
                  echo "$IF: link up failed (firmware hung?), skipping carrier wait"
                fi
                if [ "$(cat /sys/class/net/$IF/carrier 2>/dev/null || echo 0)" != "1" ]; then
                  echo "$IF: still no carrier, removing and rescanning PCI device $pci"
                  echo 1 > "/sys/bus/pci/devices/$pci/remove"; sleep 2
                  echo 1 > /sys/bus/pci/rescan; sleep 15
                  ip link set "$IF" up || true
                fi
                lost=0
              fi
            fi
            sleep 5
          done
        '';
      };

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
