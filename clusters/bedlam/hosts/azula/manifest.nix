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
    {
      name = "drover";
      coordinator = true;
      expectedPort = 24000;
      tiamatTokenFile = ../../../../aspects/dev-sandbox/tiamat-router-token.sops;
    }
  ];

  module =
    { config, pkgs, ... }:
    let
      # Workers resolve `pi` from PATH; the golem flake's wrapper only pins
      # tmux/git/bash, so the harness CLI rides in via the unit's path.
      pi-coding-agent = import ../../../../pkgs/pi-coding-agent { inherit pkgs; };
      # Marvell's out-of-tree AQtion driver, built against this host's kernel.
      # It installs to .../extra/atlantic.ko; depmod's default search order is
      # "updates extra built-in" then "*" (i.e. kernel/), so the out-of-tree
      # module wins over drivers/net/ethernet/aquantia/atlantic/atlantic.ko
      # without blacklisting the name (which would kill both). Verified in the
      # built system's modules.dep/modules.alias -- see the commit message.
      # Revert = delete the boot.extraModulePackages line below.
      aqtion = import ../../../../pkgs/aqtion {
        inherit pkgs;
        kernel = config.boot.kernelPackages.kernel;
      };
      domain = config.fort.cluster.settings.domain;
      # `/private` locality is deliberately pinned to the one reviewed router
      # artifact and one Fort-owned mesh address. A new router build or mesh
      # address requires another reviewed Fort change; DNS is not authority for
      # this boundary.
      privateRouterStore = "/nix/store/qz4cczf1hhsk6m4p0lgg3ck3q6a2mz8l-tiamat-router-2bfc122";
      privateRouterRevision = "2bfc122";
      # The package's public executable is a makeWrapper launcher which execs
      # this immutable sibling; /proc therefore reports the wrapped path.
      privateRouterRuntimeExecutable = "${privateRouterStore}/bin/.tiamat-router-wrapped";
      privateProviderId = "llama-frankenstein";
      privateProviderBaseUrl = "https://llama.gisi.network/v1";
      privateProviderAddress = "100.101.0.18";
      privateLocalityActivationSql = pkgs.writeText "tiamat-router-private-locality-activate.sql" ''
        .bail on
        PRAGMA busy_timeout=5000;
        BEGIN IMMEDIATE;
        CREATE TEMP TABLE fort_assert (value INTEGER NOT NULL CHECK (value = 1));
        CREATE TEMP TABLE fort_state (mode TEXT NOT NULL CHECK (mode IN ('apply', 'already')));
        INSERT INTO fort_state
        SELECT CASE
          WHEN json_type(config, '$.locality') IS NULL
           AND json_type(config, '$.localAddresses') IS NULL THEN 'apply'
          WHEN json_type(config, '$.locality') = 'text'
           AND json_extract(config, '$.locality') = 'local'
           AND json_type(config, '$.localAddresses') = 'array'
           AND json_array_length(json_extract(config, '$.localAddresses')) = 1
           AND json_type(config, '$.localAddresses[0]') = 'text'
           AND json_extract(config, '$.localAddresses[0]') = '${privateProviderAddress}' THEN 'already'
          ELSE NULL
        END
        FROM providers
        WHERE id = '${privateProviderId}'
          AND json_valid(config)
          AND json_type(config, '$.kind') = 'text'
          AND json_extract(config, '$.kind') = 'api-key'
          AND json_type(config, '$.preset') IS NULL
          AND json_type(config, '$.baseUrl') = 'text'
          AND json_extract(config, '$.baseUrl') = '${privateProviderBaseUrl}';
        INSERT INTO fort_assert SELECT count(*) FROM fort_state;
        INSERT INTO fort_assert SELECT count(*) FROM metadata WHERE key = 'catalog_modified';
        CREATE TEMP TABLE fort_now (value TEXT NOT NULL);
        INSERT INTO fort_now VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
        UPDATE providers
        SET config = json_set(config,
              '$.locality', 'local',
              '$.localAddresses', json_array('${privateProviderAddress}')),
            updated_at = (SELECT value FROM fort_now)
        WHERE id = '${privateProviderId}'
          AND (SELECT mode FROM fort_state) = 'apply'
          AND json_valid(config)
          AND json_type(config, '$.kind') = 'text'
          AND json_extract(config, '$.kind') = 'api-key'
          AND json_type(config, '$.preset') IS NULL
          AND json_type(config, '$.baseUrl') = 'text'
          AND json_extract(config, '$.baseUrl') = '${privateProviderBaseUrl}'
          AND json_type(config, '$.locality') IS NULL
          AND json_type(config, '$.localAddresses') IS NULL;
        CREATE TEMP TABLE fort_provider_change (value INTEGER NOT NULL);
        INSERT INTO fort_provider_change VALUES (changes());
        INSERT INTO fort_assert
        SELECT value = (SELECT mode = 'apply' FROM fort_state) FROM fort_provider_change;
        UPDATE metadata
        SET value = (SELECT value FROM fort_now)
        WHERE key = 'catalog_modified'
          AND (SELECT mode FROM fort_state) = 'apply';
        INSERT INTO fort_assert
        SELECT changes() = (SELECT mode = 'apply' FROM fort_state);
        COMMIT;
        SELECT 'locality activation: ' || mode FROM fort_state;
      '';
      privateLocalityRollbackSql = pkgs.writeText "tiamat-router-private-locality-rollback.sql" ''
        .bail on
        PRAGMA busy_timeout=5000;
        BEGIN IMMEDIATE;
        CREATE TEMP TABLE fort_assert (value INTEGER NOT NULL CHECK (value = 1));
        CREATE TEMP TABLE fort_state (mode TEXT NOT NULL CHECK (mode IN ('remove', 'already')));
        INSERT INTO fort_state
        SELECT CASE
          WHEN json_type(config, '$.locality') = 'text'
           AND json_extract(config, '$.locality') = 'local'
           AND json_type(config, '$.localAddresses') = 'array'
           AND json_array_length(json_extract(config, '$.localAddresses')) = 1
           AND json_type(config, '$.localAddresses[0]') = 'text'
           AND json_extract(config, '$.localAddresses[0]') = '${privateProviderAddress}' THEN 'remove'
          WHEN json_type(config, '$.locality') IS NULL
           AND json_type(config, '$.localAddresses') IS NULL THEN 'already'
          ELSE NULL
        END
        FROM providers
        WHERE id = '${privateProviderId}'
          AND json_valid(config)
          AND json_type(config, '$.kind') = 'text'
          AND json_extract(config, '$.kind') = 'api-key'
          AND json_type(config, '$.preset') IS NULL
          AND json_type(config, '$.baseUrl') = 'text'
          AND json_extract(config, '$.baseUrl') = '${privateProviderBaseUrl}';
        INSERT INTO fort_assert SELECT count(*) FROM fort_state;
        INSERT INTO fort_assert SELECT count(*) FROM metadata WHERE key = 'catalog_modified';
        CREATE TEMP TABLE fort_now (value TEXT NOT NULL);
        INSERT INTO fort_now VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
        UPDATE providers
        SET config = json_remove(config, '$.locality', '$.localAddresses'),
            updated_at = (SELECT value FROM fort_now)
        WHERE id = '${privateProviderId}'
          AND (SELECT mode FROM fort_state) = 'remove'
          AND json_valid(config)
          AND json_type(config, '$.kind') = 'text'
          AND json_extract(config, '$.kind') = 'api-key'
          AND json_type(config, '$.preset') IS NULL
          AND json_type(config, '$.baseUrl') = 'text'
          AND json_extract(config, '$.baseUrl') = '${privateProviderBaseUrl}'
          AND json_type(config, '$.locality') = 'text'
          AND json_extract(config, '$.locality') = 'local'
          AND json_type(config, '$.localAddresses') = 'array'
          AND json_array_length(json_extract(config, '$.localAddresses')) = 1
          AND json_type(config, '$.localAddresses[0]') = 'text'
          AND json_extract(config, '$.localAddresses[0]') = '${privateProviderAddress}';
        CREATE TEMP TABLE fort_provider_change (value INTEGER NOT NULL);
        INSERT INTO fort_provider_change VALUES (changes());
        INSERT INTO fort_assert
        SELECT value = (SELECT mode = 'remove' FROM fort_state) FROM fort_provider_change;
        UPDATE metadata
        SET value = (SELECT value FROM fort_now)
        WHERE key = 'catalog_modified'
          AND (SELECT mode FROM fort_state) = 'remove';
        INSERT INTO fort_assert
        SELECT changes() = (SELECT mode = 'remove' FROM fort_state);
        COMMIT;
        SELECT 'locality rollback: ' || mode FROM fort_state;
      '';
      # The admin principal's Fort public key is also selected for root by its
      # `root` role in common/host.nix. Reuse that exact principal here rather
      # than copying public-key material into this host manifest.
      kevinFortPublicKey = config.fort.cluster.settings.principals.admin.publicKey;
      familiarHome = "/home/familiar";
      # NixOS installs privileged programs as wrappers here. systemd's `path`
      # option expects package roots and appends /bin, so use the parent rather
      # than adding pkgs.sudo (whose store binary is not privileged).
      privilegedWrapperRoot = "/run/wrappers";
      familiarPiServices = [
        "familiar-instance-presence"
        "golemd"
      ];
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
      # Projects browser and Familiar UI bridge: fixed loopback ports, unused
      # elsewhere on this host. Familiar UI must be stable because nginx is the
      # same-origin broker; the bridge itself remains bound to 127.0.0.1.
      projectsPort = 8794;
      familiarUiPort = 8795;
      familiarUiOrigin = "https://familiar-ui.${domain}";
      familiarUiProfile = "/nix/var/nix/profiles/fort-tracked-familiar-ui/profile";
      familiarUiDescriptor = "/run/familiar-ui/bridge.json";
      familiarUiSocket = "/run/familiar-ui/broker.sock";
      # familiar.sh derives this from Kestrel's config directory as
      # $STATE_DIR/pi, then exports it as PI_CODING_AGENT_DIR.
      familiarPiAgentDir = "${kestrelDir}/state/pi";
      # Pi 0.84 documents $PI_CODING_AGENT_DIR/extensions/*/index.js as its
      # global auto-discovered, /reload-compatible extension location.
      familiarUiExtensionDir = "${familiarPiAgentDir}/extensions/familiar-ui";
      familiarUiExtensionPath = "${familiarUiExtensionDir}/index.js";
      familiarUiProfileExtension = "${familiarUiProfile}/share/familiar-ui/packages/extension/dist/index.js";
      familiarPlateDir = "${kestrelDir}/state/plate";
      familiarPlateFile = "${familiarPlateDir}/plate.json";
      # Exact familiar-ui authenticated JSON limit: 16 MiB + 64 KiB. Keep
      # this location boundary in bytes so nginx and the backend cannot drift
      # through unit rounding.
      familiarUiMaxBodySize = "16842752";
      familiarUiAccessLogFormat = ''$time_iso8601 $remote_addr "$request_method $uri" $status $body_bytes_sent'';
      familiarUiDescriptorProxyConfig = ''
        auth_request /_identity/validate;
        error_page 401 = @identity_login;
        proxy_set_header Host $host;
        proxy_set_header Cookie "";
        proxy_set_header Authorization "";
      '';
      familiarUiProxyConfig = ''
        auth_request /_identity/validate;
        error_page 401 = @identity_login;
        client_max_body_size ${familiarUiMaxBodySize};
        proxy_http_version 1.1;
        # auth_request runs in nginx's access phase before the proxy content
        # handler reads this body. Streaming therefore avoids a temp-file copy
        # without sending unauthenticated bytes upstream; client_max_body_size
        # remains enforced while nginx reads a chunked request.
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_cache off;
        gzip off;
        proxy_set_header Connection "";
        proxy_set_header Host 127.0.0.1:${toString familiarUiPort};
        proxy_set_header Origin $http_origin;
        proxy_set_header Authorization $http_authorization;
        proxy_set_header Cookie "";
        proxy_read_timeout 600s;
      '';
      # Extract exact Host values from a location's explicit config. Together
      # with recommendedProxySettings=false, this proves nginx can render only
      # the one Host directive required by each trust boundary.
      proxyHostValues =
        extraConfig:
        map builtins.head (
          builtins.filter (match: match != null) (
            map (builtins.match "[[:space:]]*proxy_set_header Host ([^;]+);[[:space:]]*") (
              pkgs.lib.splitString "\n" extraConfig
            )
          )
        );
      clientMaxBodyValues =
        extraConfig:
        map builtins.head (
          builtins.filter (match: match != null) (
            map (builtins.match "[[:space:]]*client_max_body_size ([^;]+);[[:space:]]*") (
              pkgs.lib.splitString "\n" extraConfig
            )
          )
        );
      # Kevin's Slidev workspace. Only the generated `public/` output tree is
      # ever published: the repository root (Markdown sources, node_modules,
      # .git) is outside both the vhost root and the nginx bind mount.
      slidesRepoDir = "${familiarHome}/Projects/slides";
      slidesPublicRoot = "${slidesRepoDir}/public";
      # Regex location, so a deep link inside a deck falls back to that deck's
      # own index.html (Slidev's history router) rather than 404ing or leaking
      # into a neighbouring deck. nginx normalizes $uri before matching and the
      # capture cannot contain "/" or start with ".", so the fallback target is
      # always exactly <root>/asg/<deck>/index.html.
      slidesDeckLocation = "~ ^/asg/(?<deck>[A-Za-z0-9][A-Za-z0-9._-]*)/";
      # Regex locations win over the generic module's "/" prefix location, so
      # this block has to restate the identity wall it would otherwise inherit
      # from it. (There is no other regex location on this vhost.)
      slidesDeckConfig = ''
        auth_request /_identity/validate;
        more_set_headers 'WWW-Authenticate: Bearer resource_metadata="https://$host/.well-known/oauth-protected-resource"';
        error_page 401 = @identity_login;
        # Slidev's build output contains no Markdown, but refuse to serve deck
        # source even if a future build step copies it into public/.
        if ($uri ~* "\.(md|markdown)$") {
          return 404;
        }
        index index.html;
        autoindex off;
        try_files $uri $uri/ /asg/$deck/index.html =404;
      '';
      projectsStateDir = "/var/lib/projects";
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
      # Loaded by the resident Pi only on Kevin's explicit /reload (or its next
      # birth). Set the process environment before resolving the mutable tracked
      # profile to an immutable store file URL. The dynamic URL prevents Node's
      # ESM cache from retaining an old profile generation across /reload.
      familiarUiExtensionSource = ''
        import { realpath } from "node:fs/promises";
        import { pathToFileURL } from "node:url";

        export default async function familiarUi(pi) {
          process.env.FAMILIAR_UI_ORIGIN = ${builtins.toJSON familiarUiOrigin};
          process.env.FAMILIAR_UI_PORT = ${builtins.toJSON (toString familiarUiPort)};
          process.env.FAMILIAR_UI_DESCRIPTOR = ${builtins.toJSON familiarUiDescriptor};
          process.env.FAMILIAR_PLATE_FILE = ${builtins.toJSON familiarPlateFile};

          const target = await realpath(${builtins.toJSON familiarUiProfileExtension});
          if (!target.startsWith("/nix/store/")) {
            throw new Error("familiar-ui profile did not resolve into the immutable Nix store");
          }
          const module = await import(pathToFileURL(target).href);
          if (typeof module.default !== "function") {
            throw new Error("familiar-ui extension has no default factory");
          }
          return module.default(pi);
        }
      '';
      familiarUiExtension = pkgs.writeText "familiar-ui-extension.js" familiarUiExtensionSource;
      familiarUiStageScript = ''
        set -euo pipefail
        install -d -m 0700 ${familiarPiAgentDir}/extensions
        install -d -m 0700 ${familiarUiExtensionDir}
        install -d -m 0700 ${familiarPlateDir}
        ln -sfn ${familiarUiExtension} ${familiarUiExtensionPath}
      '';
      golemdConfig = pkgs.writeText "golemd-azula.toml" ''
        name = "azula"
        clone_enabled = true
        api_bearer_tokens = []

        [providers.llama]
        base_url = "https://llama.gisi.network/v1"
        api_key_env = ""

        # Tiamat owns the compatible model/provider inventory. Golem pins the
        # authorized catalogue row per job; no upstream OAuth state lives here.
        [tiamat]
        cache_ttl = "30s"
        stale_ttl = "10m"
        timeout = "5s"
        max_models = 5000
        max_response_bytes = 8388608

        [harnesses.pi]
        # Explicit non-router fallback; dynamic models are discovered above.
        models = [ "llama/Qwen3.8-27B-UD-Q4_K_XL" ]

        [harnesses.fake]
        models = []

        [projects.scratch]
        path = "/var/lib/golem/projects/scratch"
        description = "Azula scratch repository"

        # Golemd owns the bundled foreground Herdr child and its namespace.
        # Never attach to a user's ambient Herdr or manage a sibling service.
        [herdr]
        root = "/var/lib/golem/herdr"
        session = "golem"
        server_startup_timeout = "15s"
        startup_timeout_ms = 60000
        reconcile_interval = "15s"

        [herdr.kinds]
        pi = "pi"

        [attach_ssh]
        port = 0
      '';
    in
    {
      config.fort.host = { inherit roles apps aspects; };

      # Drover MVP rendezvous validation: independent OpenSSH and TLS/control
      # listeners. Node SSH and reverse routes stay loopback-only; no route
      # range is opened. Service lifecycle remains manually managed for now.
      config.networking.firewall.allowedTCPPorts = [
        9840
        9841
      ];

      # Hard-hang mitigation (2026-09-04). Three whole-host lock-ups in one
      # evening, each showing ~27 GB free, load < 1, temps < 60 °C on the
      # last Prometheus scrape before going dark — no resource ramp, just
      # gone. Kernel 6.12 is early for this Strix Point APU (HX 470 / 890M);
      # amdgpu already logs a DCN REG_WAIT timeout at every boot. Track the
      # newest kernel on this host only; other hosts keep the default.
      config.boot.kernelPackages = pkgs.linuxPackages_latest;

      # Aquantia AQC113CS: the in-kernel `atlantic` driver wedges the NIC
      # firmware every few hours ("Boot code hanged", aq_a2_fw_deinit) and the
      # link never comes back; the vendor driver does not. See pkgs/aqtion.
      config.boot.extraModulePackages = [ aqtion ];

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
        # Add Kevin's existing Fort identity without replacing keys contributed
        # by another module. This enables direct interactive SSH and SCP/SFTP.
        openssh.authorizedKeys.keys = pkgs.lib.mkAfter [ kevinFortPublicKey ];
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

      # NixOS's wrapper module adds /run/wrappers/bin to login-shell PATH, but
      # these services declare `path`, which gives them a closed, explicit PATH
      # and bypasses shell initialization. Presence owns Exo's resident Pi;
      # golemd owns delegated Pi workers. Put the privileged wrapper first in
      # both inherited environments. Group/sudoers authorization alone cannot
      # make an executable discoverable, and pkgs.sudo would select the
      # unprivileged store program rather than NixOS's setuid wrapper.
      config.systemd.services.familiar-instance-presence.path = pkgs.lib.mkBefore [
        privilegedWrapperRoot
      ];
      config.systemd.services.golemd.path = pkgs.lib.mkBefore [ privilegedWrapperRoot ];

      # Guard the effective generated PATH, not merely the input `path` list.
      config.assertions =
        (map (service: {
          assertion = builtins.elem config.security.wrapperDir (
            pkgs.lib.splitString ":" config.systemd.services.${service}.environment.PATH
          );
          message = "${service}: familiar's Pi environment must contain ${config.security.wrapperDir}";
        }) familiarPiServices)
        ++ [
          {
            assertion =
              builtins.elem kevinFortPublicKey config.users.users.root.openssh.authorizedKeys.keys
              &&
                builtins.length (
                  builtins.filter (
                    key: key == kevinFortPublicKey
                  ) config.users.users.familiar.openssh.authorizedKeys.keys
                ) == 1;
            message = "azula SSH: Kevin's Fort key must remain authorized for root and occur exactly once for familiar";
          }
          {
            assertion = !config.systemd.services.familiar-instance-presence.restartIfChanged;
            message = "familiar-ui: Nix activation must not restart resident Presence";
          }
          {
            assertion = !config.systemd.services.familiar-instance-presence.stopIfChanged;
            message = "familiar-ui: Nix activation must not stop resident Presence";
          }
          {
            assertion =
              !(builtins.elem "familiar-instance-presence.service" config.fort.tracked.familiar-ui.restartUnits);
            message = "familiar-ui: tracked updates must not restart resident Presence";
          }
          {
            assertion = config.fort.tracked.familiar-ui.branch == "main";
            message = "familiar-ui: production must track reviewed main";
          }
          {
            assertion = familiarUiExtensionPath == "/var/lib/kestrel/state/pi/extensions/familiar-ui/index.js";
            message = "familiar-ui: wrapper must use Kestrel's actual Pi global extension directory";
          }
          {
            assertion =
              !(builtins.hasAttr "FAMILIAR_PI_EXTRA_EXTENSIONS_JSON" config.systemd.services.familiar-instance-presence.environment);
            message = "familiar-ui: auto-discovery must not be duplicated through explicit settings";
          }
          {
            assertion = builtins.all (directive: pkgs.lib.hasInfix directive familiarUiProxyConfig) [
              "auth_request /_identity/validate;"
              "error_page 401 = @identity_login;"
              "client_max_body_size ${familiarUiMaxBodySize};"
              "proxy_http_version 1.1;"
              "proxy_request_buffering off;"
              "proxy_buffering off;"
              "proxy_cache off;"
              "gzip off;"
              ''proxy_set_header Connection "";''
              "proxy_set_header Origin $http_origin;"
              "proxy_set_header Authorization $http_authorization;"
              ''proxy_set_header Cookie "";''
              "proxy_read_timeout 600s;"
            ];
            message = "familiar-ui: /v1 must preserve its exact body limit and SSE/security directives";
          }
          {
            assertion =
              let
                locations = config.services.nginx.virtualHosts."familiar-ui.${domain}".locations;
              in
              familiarUiMaxBodySize != "0"
              && clientMaxBodyValues locations."^~ /v1/".extraConfig == [ familiarUiMaxBodySize ]
              && clientMaxBodyValues locations."/".extraConfig == [ ]
              && clientMaxBodyValues locations."= /__familiar/bridge.json".extraConfig == [ ]
              && clientMaxBodyValues locations."= /_identity/validate".extraConfig == [ "0" ]
              && clientMaxBodyValues locations."/_identity/".extraConfig == [ ];
            message = "familiar-ui: only /v1 may receive the exact bounded image request ceiling";
          }
          {
            assertion =
              familiarPlateFile == "/var/lib/kestrel/state/plate/plate.json"
              && pkgs.lib.hasInfix "process.env.FAMILIAR_PLATE_FILE = ${builtins.toJSON familiarPlateFile};" familiarUiExtensionSource;
            message = "familiar-ui: wrapper must export the canonical private durable Plate path";
          }
          {
            assertion =
              config.systemd.services.familiar-ui-stage.serviceConfig.User == "familiar"
              && config.systemd.services.familiar-ui-stage.serviceConfig.Group == "users"
              && pkgs.lib.hasInfix "install -d -m 0700 ${familiarPlateDir}" familiarUiStageScript
              && !(pkgs.lib.hasInfix familiarPlateFile familiarUiStageScript);
            message = "familiar-ui: staging must create only Plate's private parent directory as familiar:users";
          }
          {
            assertion =
              let
                locations = config.services.nginx.virtualHosts."familiar-ui.${domain}".locations;
                descriptor = locations."= /__familiar/bridge.json";
                bridge = locations."^~ /v1/";
              in
              !descriptor.recommendedProxySettings
              && !bridge.recommendedProxySettings
              && proxyHostValues descriptor.extraConfig == [ "$host" ]
              && proxyHostValues bridge.extraConfig == [ "127.0.0.1:${toString familiarUiPort}" ];
            message = "familiar-ui: custom proxy locations must render exactly one boundary-specific Host header without NixOS proxy defaults";
          }
          {
            assertion =
              pkgs.lib.hasInfix ''proxy_set_header Authorization "";''
                config.services.nginx.virtualHosts."familiar-ui.${domain}".locations."= /_identity/validate".extraConfig;
            message = "familiar-ui: identity SSO must not consume the bridge bearer";
          }
          {
            assertion =
              familiarUiAccessLogFormat
              == ''$time_iso8601 $remote_addr "$request_method $uri" $status $body_bytes_sent'';
            message = "familiar-ui: dedicated access log format must remain credential/query safe";
          }
          {
            assertion =
              let
                vhostConfig = config.services.nginx.virtualHosts."familiar-ui.${domain}".extraConfig;
              in
              pkgs.lib.hasInfix "error_log /var/log/nginx/familiar-ui-error.log warn;" vhostConfig
              && !(pkgs.lib.hasInfix " debug;" vhostConfig);
            message = "familiar-ui: vhost error logging must never use debug";
          }
          # --- slides.gisi.network -------------------------------------------
          {
            assertion =
              slidesPublicRoot == "/home/familiar/Projects/slides/public"
              && config.services.nginx.virtualHosts."slides.${domain}".root == slidesPublicRoot;
            message = "slides: vhost root must be exactly the generated public/ output tree";
          }
          {
            assertion =
              let
                locations = config.services.nginx.virtualHosts."slides.${domain}".locations;
              in
              pkgs.lib.hasInfix "auth_request /_identity/validate;" locations."/".extraConfig
              && pkgs.lib.hasInfix "auth_request /_identity/validate;" locations.${slidesDeckLocation}.extraConfig
              &&
                pkgs.lib.hasInfix ''X-Identity-Required-Groups "admin"''
                  locations."= /_identity/validate".extraConfig
              && locations ? "@identity_login";
            message = "slides: every content location must sit behind the identity wall (admin)";
          }
          {
            assertion =
              let
                binds = config.systemd.services.nginx.serviceConfig.BindReadOnlyPaths;
              in
              config.systemd.services.nginx.serviceConfig.ProtectHome == "tmpfs"
              && builtins.elem "-${slidesPublicRoot}" binds
              && !(builtins.elem slidesRepoDir binds)
              && !(builtins.elem "-${slidesRepoDir}" binds)
              && !(builtins.elem familiarHome binds)
              && !(builtins.elem "-${familiarHome}" binds);
            message = "slides: nginx may bind only the public output tree, never the repository or home";
          }
          {
            assertion =
              builtins.elem "d ${slidesRepoDir} 0711 familiar users -" config.systemd.tmpfiles.rules
              && builtins.elem "d ${slidesPublicRoot} 0755 familiar users -" config.systemd.tmpfiles.rules
              && !(builtins.elem "d ${slidesRepoDir} 0755 familiar users -" config.systemd.tmpfiles.rules);
            message = "slides: only the generated output tree may be world-traversable/readable";
          }
          {
            assertion =
              let
                locations = config.services.nginx.virtualHosts."slides.${domain}".locations;
                rendered = pkgs.lib.concatStringsSep "\n" (
                  map (name: locations.${name}.extraConfig) (builtins.attrNames locations)
                );
              in
              !(pkgs.lib.hasInfix "autoindex on" rendered)
              && pkgs.lib.hasInfix "autoindex off;" locations."/".extraConfig
              && pkgs.lib.hasInfix "autoindex off;" locations.${slidesDeckLocation}.extraConfig
              && pkgs.lib.hasInfix "index index.html;" locations."/".extraConfig
              && pkgs.lib.hasInfix "index index.html;" locations.${slidesDeckLocation}.extraConfig;
            message = "slides: directories must resolve through index.html with autoindex disabled";
          }
          {
            assertion =
              let
                deck =
                  config.services.nginx.virtualHosts."slides.${domain}".locations.${slidesDeckLocation}.extraConfig;
              in
              slidesDeckLocation == "~ ^/asg/(?<deck>[A-Za-z0-9][A-Za-z0-9._-]*)/"
              && pkgs.lib.hasInfix "try_files $uri $uri/ /asg/$deck/index.html =404;" deck
              && pkgs.lib.hasInfix ''if ($uri ~* "\.(md|markdown)$")'' deck
              && pkgs.lib.hasInfix "return 404;" deck;
            message = "slides: per-deck fallback must stay inside one deck and never serve source Markdown";
          }
          {
            assertion =
              let
                presence = config.systemd.services.familiar-instance-presence;
                presenceUnitRefs =
                  presence.after ++ presence.wants ++ presence.requires ++ presence.bindsTo ++ presence.wantedBy;
              in
              !(builtins.elem "nginx.service" presenceUnitRefs)
              && !(pkgs.lib.hasInfix slidesRepoDir (toString (presence.serviceConfig.ExecStart or "")))
              && !(pkgs.lib.hasInfix slidesRepoDir (toString (presence.serviceConfig.WorkingDirectory or "")))
              && !(builtins.elem "familiar-instance-presence.service" config.systemd.services.nginx.after)
              && !(builtins.any (unit: pkgs.lib.hasInfix "presence" (toString unit)) (
                config.systemd.services.nginx.restartTriggers or [ ]
              ));
            message = "slides: static publishing must be unrelated to the Familiar Presence lifecycle";
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
        # Familiar 3 (~/Projects/familiar-three), dev mode: the unit below
        # runs the checkout's own launcher. Formal packaging comes later.
        {
          name = "familiar3";
          port = 8770;
          visibility = "public";
          sso = {
            mode = "identity";
            groups = [ "admin" ];
          };
        }
        # Reproducibly built familiar-ui shell. Only static assets are served
        # here; the descriptor broker and /v1 bridge routes are overridden
        # below, behind the same identity wall.
        {
          name = "familiar-ui";
          staticRoot = "${familiarUiProfile}/share/familiar-ui/web";
          visibility = "public";
          sso = {
            mode = "identity";
            groups = [ "admin" ];
          };
          health.enabled = false;
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
        # Slides: Kevin's Slidev workspace, published as generated files only.
        # staticRoot is the build output tree, so https://slides.<domain>/asg/<deck>/
        # resolves to <root>/asg/<deck>/index.html. Health checks are off: the
        # identity wall answers 302, and the tree is legitimately empty until a
        # deck has been built.
        {
          name = "slides";
          staticRoot = slidesPublicRoot;
          visibility = "public";
          sso = {
            mode = "identity";
            groups = [ "admin" ];
          };
          health.enabled = false;
        }
      ];

      # nginx's unit runs with ProtectHome=true, so the static root has to be
      # bind-mounted into its namespace anyway (same idiom as apps/vault). That
      # also means /home/familiar itself never has to become traversable: the
      # only mode this host relaxes is the wireframes directory (0755 below).
      # The slides entry binds only the generated output tree, never the
      # repository root. Its "-" prefix keeps a missing directory from failing
      # the whole nginx unit (every other vhost on this host lives in it); the
      # tmpfiles rules below create it first, so the prefix is belt-and-braces.
      config.systemd.services.nginx.serviceConfig = {
        ProtectHome = pkgs.lib.mkForce "tmpfs";
        BindReadOnlyPaths = [
          "${familiarHome}/Projects/wireframes"
          "-${slidesPublicRoot}"
        ];
      };

      # Slides vhost. The generic static location already emits
      # `try_files $uri $uri/ =404` plus the identity wall; extraConfig is
      # types.lines, so this appends the index/no-autoindex policy. Per-deck
      # SPA fallback lives in its own regex location (a second try_files in
      # "/" would be a duplicate-directive error).
      config.services.nginx.virtualHosts."slides.${domain}" = {
        locations."/".extraConfig = ''
          index index.html;
          autoindex off;
        '';
        locations.${slidesDeckLocation}.extraConfig = slidesDeckConfig;
      };

      # Serve index.html for directories, with an autoindex fallback for the
      # bare drafts. The generic static location (common/fort/nginx.nix) only
      # emits try_files; extraConfig is types.lines, so this appends.
      config.services.nginx.virtualHosts."wireframes.${domain}".locations."/".extraConfig = ''
        index index.html;
        autoindex on;
      '';

      # The generic static vhost handles /. These two exact trust-boundary
      # routes retain identity auth, then proxy to private local transports.
      # /v1 rewrites Host to the bridge's actual bound address: familiar-ui
      # still performs its own exact Origin, Host/DNS-rebinding, and bearer
      # checks rather than trusting reverse-proxy headers.
      # This vhost gets a private log format: its request field contains only
      # method plus nginx's normalized, argument-free $uri. In particular it
      # can never serialize the bridge bearer or an accidental query token.
      config.services.nginx.commonHttpConfig = pkgs.lib.mkAfter ''
        log_format familiar_ui_safe '${familiarUiAccessLogFormat}';
      '';
      config.services.nginx.virtualHosts."familiar-ui.${domain}" = {
        # Use one server block for both listeners so the dedicated safe access
        # and warn-level error logs also cover cleartext redirect requests.
        # The literal-origin redirect drops path and query rather than reflect
        # any attacker-controlled request data into its Location header.
        forceSSL = pkgs.lib.mkForce false;
        addSSL = true;
        extraConfig = pkgs.lib.mkAfter ''
          if ($scheme = http) {
            return 301 ${familiarUiOrigin}/;
          }
          access_log /var/log/nginx/familiar-ui-access.log familiar_ui_safe;
          # Debug-level nginx errors can include request headers. Pin this
          # credential-bearing vhost at warn even if global verbosity changes.
          error_log /var/log/nginx/familiar-ui-error.log warn;
          more_set_headers "Content-Security-Policy: default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'";
          more_set_headers "Referrer-Policy: no-referrer";
        '';
        locations."= /__familiar/bridge.json" = {
          proxyPass = "http://unix:${familiarUiSocket}";
          # Global recommended proxy settings would append another Host header.
          # This boundary intentionally sends only the public request Host.
          recommendedProxySettings = false;
          extraConfig = familiarUiDescriptorProxyConfig;
        };
        locations."^~ /v1/" = {
          proxyPass = "http://127.0.0.1:${toString familiarUiPort}";
          # The bridge's DNS-rebinding check requires its loopback authority;
          # never append NixOS's conflicting `Host $host` proxy default.
          recommendedProxySettings = false;
          extraConfig = familiarUiProxyConfig;
        };
        # The /v1 Authorization header is the bridge bearer, not an identity
        # token. Replace the generic identity subrequest configuration so this
        # browser lane authenticates solely with the SSO cookie, then pass the
        # untouched bearer only to the loopback bridge. mkForce avoids emitting
        # two Authorization directives whose duplicate-header behavior would
        # otherwise depend on nginx internals.
        locations."= /_identity/validate".extraConfig = pkgs.lib.mkForce ''
          internal;
          client_max_body_size 0;
          proxy_pass http://unix:/run/identity-proxy/identity-proxy.sock;
          proxy_pass_request_body off;
          proxy_set_header Content-Length "";
          proxy_set_header X-Original-URI $request_uri;
          proxy_set_header X-Original-Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Identity-Required-Groups "admin";
          proxy_set_header Authorization "";
        '';
      };

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
              (action.lookup("unit") == "unfamiliar.service" ||
               action.lookup("unit") == "familiar3.service") &&
              subject.user == "familiar") {
            return polkit.Result.YES;
          }
        });
      '';

      config.systemd.services.unfamiliar = {
        description = "Unfamiliar — persistent presence on the pi SDK";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "sops-nix.service"
          "golemd.service"
        ];
        wants = [ "network-online.target" ];
        # tmux is the client half of shepherd's peer-in terminal: it attaches
        # to golemd's worker sessions at /var/lib/golem/tmux.sock.
        path = with pkgs; [
          unfamiliarBun
          nodejs_22
          git
          bashInteractive
          coreutils
          tmux
        ];
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

      # Familiar 3, dev mode. Deliberately broad: the checkout's `just start`
      # is the whole contract (build, then run). Deploy = merge to the checkout
      # and `systemctl restart familiar3`. State in /var/lib/familiar3, sockets
      # in /run/familiar3 — both created by systemd, both owned by familiar.
      config.systemd.services.familiar3 = {
        description = "Familiar 3 — dev-mode instance from ~/Projects/familiar-three";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        path = with pkgs; [
          nix
          git
          just
          bashInteractive
          coreutils
        ];
        environment.HOME = familiarHome;
        serviceConfig = {
          User = "familiar";
          Group = "users";
          WorkingDirectory = "${familiarHome}/Projects/familiar-three";
          ExecStart = "${pkgs.nix}/bin/nix develop --command just start";
          StateDirectory = "familiar3";
          RuntimeDirectory = "familiar3";
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
        # 0755 (the tmpfiles default this rule already produced, now
        # explicit): services outside the familiar account traverse this
        # directory — nginx for wireframes, projects-browser for the tree.
        "d ${familiarHome}/Projects 0755 familiar users -"
        "d ${familiarHome}/Projects/wireframes 0755 familiar users -"
        # Slides: the repository directory only has to exist and be traversable
        # by its owner, so it stays 0711 -- Markdown sources and git history are
        # not readable by other local accounts. Only the generated output tree
        # is 0755, which is the minimum for the nginx worker (a different uid)
        # to traverse it and read 0644 build artifacts. Both rules run before
        # nginx starts, so the bind mount always has a source even when the
        # checkout has never been built (or does not exist yet).
        "d ${slidesRepoDir} 0711 familiar users -"
        "d ${slidesPublicRoot} 0755 familiar users -"
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

      # This reconciliation runs as the router account and never selects,
      # decrypts, or rewrites the credential column. PartOf makes every overlay
      # manager stop/restart re-run the exact binary gate: an older or merely
      # different router artifact leaves this unit failed and the required
      # overlay service stopped rather than serving a persisted local claim.
      config.systemd.services.tiamat-router-private-locality = {
        description = "Classify the reviewed llama provider as Fort-local";
        wantedBy = [ "multi-user.target" ];
        before = [ "overlay-tiamat-router.service" ];
        after = [ "tiamat-router-bootstrap-provision.service" ];
        requires = [ "tiamat-router-bootstrap-provision.service" ];
        partOf = [ "overlay-tiamat-router.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "tiamat-router";
          Group = "tiamat-router";
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/var/lib/tiamat-router" ];
        };
        path = [
          pkgs.coreutils
          pkgs.gnused
          pkgs.systemd
        ];
        script = ''
          set -euo pipefail
          expected=${privateRouterStore}/bin/tiamat-router
          unit_exec="$(${pkgs.systemd}/bin/systemctl show --property=ExecStart --value overlay-tiamat-router.service)"
          configured="$(printf '%s\n' "$unit_exec" | ${pkgs.gnused}/bin/sed -n 's/^{ path=\([^ ;]*\) .*/\1/p')"
          test "$configured" = "$expected"
          test "$($expected version)" = '${privateRouterRevision}'

          pid="$(${pkgs.systemd}/bin/systemctl show --property=MainPID --value overlay-tiamat-router.service)"
          if test "$pid" != 0; then
            test "$(${pkgs.coreutils}/bin/readlink -f "/proc/$pid/exe")" = '${privateRouterRuntimeExecutable}'
          fi

          db=/var/lib/tiamat-router/tiamat.db
          test -O "$db"
          before="$(${pkgs.coreutils}/bin/stat -c '%u:%g:%a' "$db")"
          test "''${before##*:}" = 600
          ${pkgs.sqlite}/bin/sqlite3 "$db" < ${privateLocalityActivationSql}
          after="$(${pkgs.coreutils}/bin/stat -c '%u:%g:%a' "$db")"
          test "$after" = "$before"
        '';
      };

      # Emergency fail-closed rollback. Starting this conflicts with (and thus
      # stops) the router and its active classification. It only removes the two
      # reviewed JSON fields. Revert this Fort activation before starting the
      # router again, otherwise the required activation unit will re-apply it.
      config.systemd.services.tiamat-router-private-locality-rollback = {
        description = "Remove the reviewed llama provider locality classification";
        conflicts = [
          "overlay-tiamat-router.service"
          "tiamat-router-private-locality.service"
        ];
        before = [ "overlay-tiamat-router.service" ];
        after = [ "tiamat-router-bootstrap-provision.service" ];
        requires = [ "tiamat-router-bootstrap-provision.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "tiamat-router";
          Group = "tiamat-router";
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/var/lib/tiamat-router" ];
        };
        script = ''
          set -euo pipefail
          db=/var/lib/tiamat-router/tiamat.db
          test -O "$db"
          before="$(${pkgs.coreutils}/bin/stat -c '%u:%g:%a' "$db")"
          test "''${before##*:}" = 600
          ${pkgs.sqlite}/bin/sqlite3 "$db" < ${privateLocalityRollbackSql}
          after="$(${pkgs.coreutils}/bin/stat -c '%u:%g:%a' "$db")"
          test "$after" = "$before"
        '';
      };

      config.systemd.units."overlay-tiamat-router.service" = {
        overrideStrategy = "asDropin";
        text = ''
          [Unit]
          Requires=tiamat-router-bootstrap-provision.service
          After=tiamat-router-bootstrap-provision.service
          Requires=tiamat-router-private-locality.service
          After=tiamat-router-private-locality.service
        '';
      };

      # Production familiar-ui package. The private repository is fetched by
      # the established Familiar gh credential below, never by an evaluation-
      # time unauthenticated fetch. Updates may restart only the stateless
      # broker/stager; Presence is deliberately absent from restartUnits.
      config.fort.tracked.familiar-ui = {
        repo = "gisikw/familiar-ui";
        branch = "main";
        flakeAttr = "familiar-ui";
        autoUpdate = true;
        pollInterval = "15m";
        exec = null;
        user = "familiar";
        group = "users";
        restartUnits = [
          "familiar-ui-stage.service"
          "familiar-ui-broker.service"
        ];
      };

      # Stage in Pi's documented global auto-discovery directory. This never
      # reads or writes settings.json, so it cannot race Pi 0.84's own
      # proper-lockfile-coordinated settings persistence. /reload rescans this
      # directory; the same lane also persists naturally across the next birth.
      config.systemd.services.familiar-ui-stage = {
        description = "Stage familiar-ui in Pi's global extension directory";
        wantedBy = [ "multi-user.target" ];
        unitConfig.ConditionPathExists = familiarUiProfileExtension;
        serviceConfig = {
          Type = "oneshot";
          User = "familiar";
          Group = "users";
        };
        path = [ pkgs.coreutils ];
        script = familiarUiStageScript;
      };

      config.systemd.services.familiar-ui-broker = {
        description = "Familiar UI protected descriptor broker";
        after = [ "fort-tracked-familiar-ui-fetch.service" ];
        unitConfig.ConditionPathExists = "${familiarUiProfile}/bin/familiar-ui-broker";
        wantedBy = [ "multi-user.target" ];
        environment = {
          FAMILIAR_UI_DESCRIPTOR = familiarUiDescriptor;
          FAMILIAR_UI_PUBLIC_ORIGIN = familiarUiOrigin;
          FAMILIAR_UI_ORIGIN = familiarUiOrigin;
          FAMILIAR_UI_PORT = toString familiarUiPort;
          FAMILIAR_UI_BROKER_SOCKET = familiarUiSocket;
        };
        serviceConfig = {
          User = "familiar";
          Group = "nginx";
          ExecStart = "${familiarUiProfile}/bin/familiar-ui-broker";
          RuntimeDirectory = "familiar-ui";
          RuntimeDirectoryMode = "0750";
          RuntimeDirectoryPreserve = "restart";
          Restart = "on-failure";
          RestartSec = "5s";
          UMask = "0007";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ProtectProc = "invisible";
          ProcSubset = "pid";
          CapabilityBoundingSet = "";
          RestrictAddressFamilies = [ "AF_UNIX" ];
        };
      };

      # Hard activation gate: staging an extension for the next /reload or birth
      # must never bounce the current Exo. Auto-discovery makes
      # FAMILIAR_PI_EXTRA_EXTENSIONS_JSON unnecessary; omitting an explicit
      # settings entry also guarantees the extension is loaded exactly once.
      config.systemd.services.familiar-instance-presence = {
        restartIfChanged = false;
        stopIfChanged = false;
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
      # The Projects browser runs as its own least-privileged system account:
      # it only ever reads Kevin's Projects tree and writes its own database.
      config.users.groups.projects = { };
      config.users.users.projects = {
        isSystemUser = true;
        group = "projects";
        description = "Projects browser service user";
        # Home points at the state directory rather than anything under
        # /home, so nothing this account does can scribble into the tree it
        # browses (or leave a checkout there).
        home = projectsStateDir;
      };

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

      # Projects browser: read-only window onto ~familiar/Projects, tracked
      # from gisikw/projects main. Deployment cadence is the app repo's, not
      # this manifest's (see common/fort/tracked.nix); autoUpdate is safe here
      # because that branch is solely ours.
      #
      # Trust boundary: the service reads a human's working tree, so it gets
      # nothing else. ProtectHome=tmpfs blanks /home inside the namespace and
      # exactly one path is bound back in, read-only; the only writable
      # location is its own StateDirectory. IPAddressAllow=localhost is the
      # belt to the loopback bind's braces — even a misconfigured listener
      # cannot be reached off-box.
      config.fort.tracked.projects = {
        repo = "gisikw/projects";
        branch = "main";
        flakeAttr = "default";
        autoUpdate = true;
        pollInterval = "15m";
        exec = "projects-browser";
        # Fetch/build needs Familiar's GitHub credential because this is a
        # private repository. The runtime below still runs as the isolated
        # projects account; tracked state stays outside the browsed tree.
        user = "familiar";
        group = "users";
        expose = {
          subdomain = "projects";
          port = projectsPort;
          visibility = "public";
          sso = {
            mode = "identity";
            groups = [
              "admin"
              "infra"
            ];
          };
          # No health.endpoint: the app has no documented health route yet.
          # Add one here only after the app actually serves it.
        };
        unit = {
          description = "Projects browser — read-only view of ~familiar/Projects";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          environment = {
            PROJECTS_ROOT = "${familiarHome}/Projects";
            PROJECTS_DATABASE = "${projectsStateDir}/projects.db";
            PROJECTS_HOST = "127.0.0.1";
            PROJECTS_PORT = toString projectsPort;
          };
          serviceConfig = {
            User = "projects";
            Group = "projects";
            StateDirectory = "projects";
            StateDirectoryMode = "0700";
            WorkingDirectory = projectsStateDir;
            Restart = "on-failure";
            RestartSec = "5s";
            UMask = "0077";

            # ProtectHome=tmpfs hides every home directory; the single bind
            # below hands back only the tree being browsed, read-only. Same
            # idiom as nginx/wireframes above — /home/familiar as a whole is
            # never exposed.
            ProtectHome = "tmpfs";
            BindReadOnlyPaths = [ "${familiarHome}/Projects" ];
            ProtectSystem = "strict";
            ProtectProc = "invisible";
            ProcSubset = "pid";
            PrivateTmp = true;
            PrivateDevices = true;
            NoNewPrivileges = true;
            CapabilityBoundingSet = "";
            AmbientCapabilities = "";
            LockPersonality = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            RestrictNamespaces = true;
            ProtectClock = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectControlGroups = true;
            RemoveIPC = true;
            SystemCallArchitectures = "native";
            SystemCallFilter = [
              "@system-service"
              "~@privileged"
              "~@resources"
            ];
            SystemCallErrorNumber = "EPERM";
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
            IPAddressDeny = "any";
            IPAddressAllow = "localhost";
          };
        };
      };

      # fort.tracked deliberately gives fetchers an isolated HOME. Point only
      # this private-repository fetch at Familiar's gh credential and install a
      # per-process helper; the token is read at runtime and never enters the
      # Nix store. The projects runner does not inherit this environment.
      config.systemd.services.fort-tracked-projects-fetch.environment = {
        GH_CONFIG_DIR = "${familiarHome}/.config/gh";
        GIT_CONFIG_COUNT = "1";
        GIT_CONFIG_KEY_0 = "credential.https://github.com.helper";
        GIT_CONFIG_VALUE_0 = "!${pkgs.gh}/bin/gh auth git-credential";
      };
      config.systemd.services.fort-tracked-familiar-ui-fetch.environment = {
        GH_CONFIG_DIR = "${familiarHome}/.config/gh";
        GIT_CONFIG_COUNT = "1";
        GIT_CONFIG_KEY_0 = "credential.https://github.com.helper";
        GIT_CONFIG_VALUE_0 = "!${pkgs.gh}/bin/gh auth git-credential";
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
        path = with pkgs; [
          coreutils
          iproute2
          systemd
        ];
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
                  sleep 10
                fi
                if [ "$(cat /sys/class/net/$IF/carrier 2>/dev/null || echo 0)" != "1" ]; then
                  # Bounce and rescan both failed. The host itself is healthy
                  # (it's running this script), so a clean reboot re-probes
                  # the NIC through a warm reset -- which is what has actually
                  # revived it every time so far. Guard: never within 15 min
                  # of boot, so a NIC that's dead at boot waits for a human
                  # instead of reboot-looping.
                  up_s=$(cut -d. -f1 /proc/uptime)
                  if [ "$up_s" -ge 900 ]; then
                    echo "$IF: rescan failed, uptime ''${up_s}s -- clean reboot"
                    systemctl reboot
                    sleep 60
                  else
                    echo "$IF: rescan failed but uptime ''${up_s}s < 900s, not rebooting"
                  fi
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
