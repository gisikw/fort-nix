# Fort Agent Module
#
# Defines fort.host.needs and fort.host.capabilities options for the unified control plane.
# See docs/control-plane-design.md for architecture details.
#
# fort.host.needs.<type>.<name>: Declares what a host needs from capability providers
# fort.host.capabilities.<name>: Declares what capabilities a host exposes
#
{ rootManifest, cluster, platform ? "nixos", ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = rootManifest.fortConfig.settings.domain;
  hostName = config.networking.hostName;
  isDarwin = platform == "darwin";

  # Read all host manifests for RBAC derivation
  hostFiles = builtins.readDir cluster.hostsDir;
  allHostManifests = builtins.mapAttrs
    (name: _: import (cluster.hostsDir + "/" + name + "/manifest.nix"))
    hostFiles;

  # Build hosts.json with peer public keys from cluster topology
  # For each host, get its device UUID and then the device's SSH public key
  getHostPubkey = hostName':
    let
      hostConfig = allHostManifests.${hostName'};
      deviceUuid = hostConfig.device;
      deviceManifestPath = cluster.devicesDir + "/${deviceUuid}/manifest.nix";
      deviceConfig = import deviceManifestPath;
    in {
      name = hostName';
      pubkey = deviceConfig.pubkey;
    };

  # Build hosts.json structure: { "hostname": { "pubkey": "ssh-ed25519 ..." }, ... }
  # Includes both hosts (from device manifests) and principals with agentKeys
  hostEntries = map (h:
    let info = getHostPubkey h;
    in { name = info.name; value = { pubkey = info.pubkey; }; }
  ) (builtins.attrNames allHostManifests);

  # Extract principals with agentKey for agent authentication
  principals = rootManifest.fortConfig.settings.principals or {};
  principalEntries = lib.mapAttrsToList (name: cfg:
    { inherit name; value = { pubkey = cfg.agentKey; }; }
  ) (lib.filterAttrs (name: cfg: cfg ? agentKey) principals);

  hostsJson = builtins.listToAttrs (hostEntries ++ principalEntries);

  fcgiSocket = "/run/fort/fcgi.sock";
  # Mandatory capability handlers (always present on all hosts) — split out
  # to common/fort/control-plane/handlers.nix (q-1f08acd9).
  mandatoryHandlers = import ./control-plane/handlers.nix {
    inherit pkgs lib config isDarwin hostName fortProvider;
  };

  # Mandatory capabilities config (all RPC - synchronous request-response)
  mandatoryCapabilities = {
    status = { mode = "rpc"; };
    manifest = { mode = "rpc"; };
    needs = { mode = "rpc"; };
    # Debug capabilities - restricted to dev-sandbox principal
    journal = { mode = "rpc"; allowed = [ "dev-sandbox" ]; };
    systemd = { mode = "rpc"; allowed = [ "dev-sandbox" ]; };
    force-nag = { mode = "rpc"; allowed = [ "dev-sandbox" ]; };
    read-file = { mode = "rpc"; allowed = [ "dev-sandbox" ]; };
    # Refresh capability - triggers re-delivery to subscribers
    # Allowed for ci (CI-triggered) and dev-sandbox (manual testing)
    refresh = { mode = "rpc"; allowed = [ "ci" "dev-sandbox" ]; };
  };

  # Helper to derive needsGC and ttl from mode
  # RPC mode: synchronous, no GC needed
  # Async mode: asynchronous with state, needs GC
  modeToGcConfig = mode: {
    needsGC = mode == "async";
    ttl = if mode == "async" then 86400 else 0;  # 24h default for async
  };

  # All capabilities = mandatory + user-defined
  # Mandatory capabilities use the new mode schema directly
  # User-defined capabilities are transformed to include derived needsGC/ttl
  allCapabilities = lib.mapAttrs (name: cfg:
    (modeToGcConfig cfg.mode) // {
      inherit (cfg) mode;
      cacheResponse = cfg.cacheResponse or false;
      triggers = cfg.triggers or { initialize = false; systemd = []; };
      format = cfg.format or "legacy";
    } // lib.optionalAttrs (cfg ? allowed) { inherit (cfg) allowed; }
  ) mandatoryCapabilities // lib.mapAttrs (name: cfg:
    (modeToGcConfig cfg.mode) // {
      inherit (cfg) mode cacheResponse triggers format;
    } // lib.optionalAttrs (cfg.allowed != null) { inherit (cfg) allowed; }
  ) config.fort.host.capabilities;

  # All hosts AND principals with agentKeys allowed to call mandatory endpoints
  principalNames = builtins.attrNames (lib.filterAttrs (name: cfg: cfg ? agentKey) principals);
  allHosts = builtins.attrNames allHostManifests ++ principalNames;

  # Derive RBAC from cluster topology
  # For each capability this host exposes, determine which hosts can call it
  deriveRbac = capabilities:
    lib.mapAttrs (capName: capCfg:
      if capCfg ? allowed && capCfg.allowed != null then
        # Restricted capability: only specified principals allowed
        capCfg.allowed
      else
        # Open capability: all cluster hosts and principals can call
        allHosts
    ) capabilities;

  # Parse duration string (e.g., "15m", "1h", "30s") to seconds
  parseDuration = str:
    let
      match = builtins.match "([0-9]+)([smh])" str;
      value = if match != null then lib.toInt (builtins.elemAt match 0) else 900;
      unit = if match != null then builtins.elemAt match 1 else "m";
    in
      if unit == "s" then value
      else if unit == "m" then value * 60
      else if unit == "h" then value * 3600
      else 900;  # default 15m

  # Need/capability option types — split out to
  # common/fort/control-plane/options.nix (q-1f08acd9).
  inherit (import ./control-plane/options.nix { inherit lib pkgs; })
    needOptions capabilityOptions;

  # Generate needs.json from all fort.host.needs declarations
  #
  # Structure: fort.host.needs.<capability>.<name> = { from, request, handler, nag }
  # The first key IS the capability name - no magic transformation.
  # Example: fort.host.needs.ssl-cert.wildcard calls the "ssl-cert" capability
  needsJson = let
    flattenNeeds = needs:
      lib.concatLists (lib.mapAttrsToList (capability:
        lib.mapAttrsToList (name: cfg: {
          id = "${capability}-${name}";
          inherit capability;
          from = cfg.from;
          request = cfg.request;
          handler = toString cfg.handler;
          nag_seconds = parseDuration cfg.nag;
          never_satisfied = cfg.neverSatisfied or false;
        } // lib.optionalAttrs (cfg.check or null != null) {
          check = toString cfg.check;
        })
      ) needs);
  in builtins.toJSON (flattenNeeds config.fort.host.needs);

  # RBAC for mandatory endpoints (respects allowed if specified)
  mandatoryRbac = deriveRbac mandatoryCapabilities;

  # Generate rbac.json from capabilities and topology (includes mandatory)
  rbacJson = builtins.toJSON (mandatoryRbac // deriveRbac config.fort.host.capabilities);

  # Generate capabilities.json with needsGC and ttl settings (includes mandatory)
  capabilitiesJson = builtins.toJSON allCapabilities;

  # Import the provider (FastCGI handler)
  fortProvider = import ../../pkgs/fort-provider { inherit pkgs; };

  # Import fort CLI for consumer service
  fortCli = import ../../pkgs/fort { inherit pkgs domain; };

  # Fulfill script — split out to common/fort/control-plane/fulfill.nix
  # (q-1f08acd9). Reads needs.json and calls providers.
  fortFulfillScript = import ./control-plane/fulfill.nix { inherit pkgs fortCli; };

  # Check if we have any needs or capabilities defined
  hasNeeds = config.fort.host.needs != { };
  hasCapabilities = config.fort.host.capabilities != { };

  # Host manifest for service discovery (darwin generates this here; NixOS
  # does it in fort/services.nix — same JSON, shared via service-lib.nix)
  hostManifestJson = pkgs.writeText "host-manifest.json"
    ((import ./service-lib.nix).hostManifestContentFor config);

  # Config installation commands shared across platforms
  fortConfigInstallScript = ''
    install -d -m0755 /etc/fort
    install -d -m0755 /etc/fort/handlers
    install -Dm0644 ${pkgs.writeText "hosts.json" (builtins.toJSON hostsJson)} /etc/fort/hosts.json

    # Install mandatory handlers
    install -Dm0755 ${mandatoryHandlers.status} /etc/fort/handlers/status
    install -Dm0755 ${mandatoryHandlers.manifest} /etc/fort/handlers/manifest
    install -Dm0755 ${mandatoryHandlers.needs} /etc/fort/handlers/needs
    install -Dm0755 ${mandatoryHandlers.journal} /etc/fort/handlers/journal
    install -Dm0755 ${mandatoryHandlers.systemd} /etc/fort/handlers/systemd
    install -Dm0755 ${mandatoryHandlers.force-nag} /etc/fort/handlers/force-nag
    install -Dm0755 ${mandatoryHandlers.read-file} /etc/fort/handlers/read-file
    install -Dm0755 ${mandatoryHandlers.refresh} /etc/fort/handlers/refresh

    # Install RBAC and capabilities config (includes mandatory endpoints)
    install -Dm0644 ${pkgs.writeText "rbac.json" rbacJson} /etc/fort/rbac.json
    # Only update capabilities.json when content changes — PathModified
    # on this file triggers a fort-provider restart, and unconditional
    # writes cause spurious restart cascades during deploys.
    _new_caps=${pkgs.writeText "capabilities.json" capabilitiesJson}
    if ! cmp -s "$_new_caps" /etc/fort/capabilities.json 2>/dev/null; then
      install -Dm0644 "$_new_caps" /etc/fort/capabilities.json
    fi

    ${lib.optionalString isDarwin ''
      # Darwin: ensure state directories exist
      install -d -m0755 /var/lib/fort
      install -d -m0755 /var/lib/fort/handles
      install -d -m0755 /var/lib/fort/status
      install -d -m0700 /var/lib/fort/tls

      # Generate self-signed TLS cert if missing (fort CLI uses curl -sk)
      if [ ! -f /var/lib/fort/tls/cert.pem ]; then
        ${pkgs.openssl}/bin/openssl req -x509 -newkey ec \
          -pkeyopt ec_paramgen_curve:prime256v1 \
          -keyout /var/lib/fort/tls/key.pem \
          -out /var/lib/fort/tls/cert.pem \
          -days 3650 -nodes \
          -subj "/CN=${hostName}.fort.${domain}" 2>/dev/null
        chmod 600 /var/lib/fort/tls/key.pem
      fi

      # Darwin: generate host-manifest.json (NixOS does this in fort.nix)
      install -Dm0644 ${hostManifestJson} /var/lib/fort/host-manifest.json
    ''}
  '';

in
{
  options.fort.host = {
    needs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.submodule { options = needOptions; }));
      default = { };
      description = ''
        Declares what this host needs from capability providers.
        Structure: fort.host.needs.<capability>.<id> = { from, request, handler, nag }

        The first key is the capability to call. The second key is an arbitrary
        identifier for disambiguation - use "default" for singletons, or a
        descriptive id when you have multiple needs of the same capability.

        The handler script receives the response payload on stdin and is
        responsible for storage, transformation, and triggering any restarts.

        Examples:
          # Simple need with inline handler
          fort.host.needs.git-token.default = {
            from = "drhorrible";
            request = { access = "ro"; };
            handler = pkgs.writeShellScript "git-token-handler" '''
              ${pkgs.jq}/bin/jq -r '.token' > /var/lib/fort-git/token
            ''';
          };

          # OIDC registration with handler
          fort.host.needs.oidc.grafana = {
            from = "drhorrible";
            request = { client_name = "grafana"; };
            nag = "1h";
            handler = ./handlers/oidc-callback.sh;
          };
      '';
      example = {
        git-token.default = {
          from = "drhorrible";
          request = { access = "ro"; };
          handler = ./handle-git-token.sh;
        };
      };
    };

    capabilities = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule { options = capabilityOptions; });
      default = { };
      description = ''
        Declares what capabilities this host exposes via the agent API.
        RBAC rules are derived automatically from cluster topology.

        Examples:
          # Simple RPC capability (synchronous request-response)
          fort.host.capabilities.ssl-cert = {
            handler = ./handlers/ssl-cert;
            mode = "rpc";
            description = "Return cluster SSL certificates";
          };

          # Async capability with state tracking (provider can GC when need removed)
          fort.host.capabilities.oidc-register = {
            handler = ./handlers/oidc-register;
            mode = "async";  # Default - tracks state, supports GC
            description = "Register OIDC client in pocket-id";
          };

          # Capability with triggers (auto-run on boot and service restart)
          fort.host.capabilities.token-sync = {
            handler = ./handlers/token-sync;
            mode = "rpc";
            triggers = {
              initialize = true;
              systemd = [ "pocket-id.service" ];
            };
            description = "Sync deploy tokens to hosts";
          };
      '';
      example = {
        ssl-cert = {
          handler = ./handlers/ssl-cert;
          mode = "rpc";
          description = "Return cluster SSL certificates";
        };
      };
    };
  };

  config = lib.mkMerge [
    # Config file installation (platform-specific activation script format)
    (if isDarwin then {
      # nix-darwin: use preActivation (postActivation may conflict with other definitions)
      system.activationScripts.preActivation.text = lib.mkAfter fortConfigInstallScript;
    } else {
      # NixOS: named activation script with dependency ordering
      system.activationScripts.fortProviderConfig = {
        deps = [ ];
        text = fortConfigInstallScript;
      };
    })

    # NixOS: systemd services + nginx reverse proxy
    (if (!isDarwin) then {
      # Runtime directory for socket
      systemd.tmpfiles.rules = [
        "d /run/fort 0755 root root -"
      ];

      # Socket activation for the FastCGI provider
      systemd.sockets.fort-provider = {
        description = "Fort Control Plane Provider Socket";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ fcgiSocket ];
        socketConfig = {
          SocketMode = "0660";
          SocketUser = "root";
          SocketGroup = "nginx";
        };
      };

      # The actual service (activated by socket)
      # stopIfChanged prevents switch-to-configuration from killing the provider
      # (and its socket) during deploys. The path watcher (fort-provider-config)
      # handles restarts when capabilities.json changes.
      systemd.services.fort-provider = {
        description = "Fort Control Plane Provider";
        requires = [ "fort-provider.socket" ];
        after = [ "fort-provider.socket" ];
        stopIfChanged = false;
        path = [ fortCli ];  # For sendCallback to invoke fort CLI

        serviceConfig = {
          Type = "simple";
          ExecStart = "${fortProvider}/bin/fort-provider";
          StandardInput = "socket";
          StandardOutput = "socket";
          StandardError = "journal";
        };
      };

      # Watch for config changes and restart fort-provider
      systemd.paths.fort-provider-config = {
        description = "Watch for fort-provider config changes";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathModified = "/etc/fort/capabilities.json";
        };
      };

      systemd.services.fort-provider-config = {
        description = "Restart fort-provider on config change";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.systemd}/bin/systemctl restart fort-provider.service";
        };
      };

      # Control plane endpoint - VPN-only access for cluster-internal communication
      services.nginx.virtualHosts."${hostName}.fort.${domain}" = {
        locations."/fort/" = {
          extraConfig = ''
            if ($is_vpn = 0) {
              return 444;
            }

            fastcgi_pass unix:${fcgiSocket};
            include ${pkgs.nginx}/conf/fastcgi_params;
            fastcgi_param SCRIPT_NAME $uri;
            fastcgi_param REQUEST_METHOD $request_method;
            fastcgi_param CONTENT_TYPE $content_type;
            fastcgi_param CONTENT_LENGTH $content_length;
            fastcgi_param QUERY_STRING $query_string;

            # Auth headers for signature verification
            fastcgi_param HTTP_X_FORT_ORIGIN $http_x_fort_origin;
            fastcgi_param HTTP_X_FORT_TIMESTAMP $http_x_fort_timestamp;
            fastcgi_param HTTP_X_FORT_SIGNATURE $http_x_fort_signature;
          '';
        };
      };
    } else {
      # Darwin: launchd services. Default is direct HTTPS on 443 (no nginx).
      # When the host declares fort.cluster.services, nginx (see
      # fort/darwin-services.nix) takes over 443 to serve those vhosts and
      # proxies /fort/ here — the provider then binds loopback:8444 so both
      # can coexist. The fort CLI contract (https://<host>.fort.<domain>/fort/)
      # is preserved in both shapes.
      launchd.daemons.fort-provider = {
        serviceConfig = {
          Label = "network.gisi.fort.provider";
          ProgramArguments = [
            "${fortProvider}/bin/fort-provider"
            "--listen" (if config.fort.cluster.services != [] then "127.0.0.1:8444" else "0.0.0.0:443")
            "--tls-cert" "/var/lib/fort/tls/cert.pem"
            "--tls-key" "/var/lib/fort/tls/key.pem"
          ];
          KeepAlive = true;
          RunAtLoad = true;
          # Respawn quickly after a crash instead of launchd's default 10s
          # throttle — early-boot failures (network/TLS state not ready yet)
          # otherwise leave the provider throttled after reboot (q-d9b7ef7b).
          ThrottleInterval = 5;
          StandardOutPath = "/var/log/fort-provider.log";
          StandardErrorPath = "/var/log/fort-provider.log";
          EnvironmentVariables = {
            PATH = "${lib.makeBinPath [ fortCli pkgs.coreutils pkgs.jq ]}:/usr/bin:/bin";
          };
        };
      };
    })

    # Generate needs.json if any needs are declared
    (lib.mkIf hasNeeds (if isDarwin then {
      system.activationScripts.preActivation.text = lib.mkAfter ''
        install -Dm0644 ${pkgs.writeText "needs.json" needsJson} /etc/fort/needs.json
      '';
    } else {
      system.activationScripts.fortNeedsJson = {
        deps = [ "fortHostManifest" ];
        text = ''
          install -Dm0644 ${pkgs.writeText "needs.json" needsJson} /etc/fort/needs.json
        '';
      };
    }))

    # Consumer services (platform-specific)
    (lib.mkIf hasNeeds (if !isDarwin then {
      systemd.services.fort-consumer = {
        description = "Fort control plane consumer";
        after = [ "network-online.target" "fort-provider.service" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        # Restart when needs change so new needs are fulfilled immediately
        restartTriggers = [ (pkgs.writeText "needs.json" needsJson) ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = fortFulfillScript;
        };

        path = [ fortCli pkgs.jq pkgs.coreutils pkgs.systemd ];
      };

      # Retry timer - periodically re-attempts unfulfilled needs
      systemd.timers.fort-consumer-retry = {
        description = "Retry unfulfilled fort consumer needs";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5m";
          OnUnitActiveSec = "5m";
        };
      };

      systemd.services.fort-consumer-retry = {
        description = "Retry unfulfilled fort consumer needs";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = fortFulfillScript;
        };

        path = [ fortCli pkgs.jq pkgs.coreutils pkgs.systemd ];
      };
    } else {
      launchd.daemons.fort-consumer = {
        serviceConfig = {
          Label = "network.gisi.fort.consumer";
          ProgramArguments = [ "${fortFulfillScript}" ];
          StartInterval = 300;  # 5 minutes
          RunAtLoad = true;
          StandardOutPath = "/var/log/fort-consumer.log";
          StandardErrorPath = "/var/log/fort-consumer.log";
          EnvironmentVariables = {
            PATH = "${lib.makeBinPath [ fortCli pkgs.jq pkgs.coreutils ]}:/usr/bin:/bin";
          };
        };
      };
    }))

    # Install user-defined capability handlers (if any)
    (lib.mkIf hasCapabilities (let
      handlerInstallScript = ''
        # Install user-defined handler scripts
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: cfg: ''
          install -Dm0755 ${cfg.handler} /etc/fort/handlers/${name}
        '') config.fort.host.capabilities)}
      '';
    in if isDarwin then {
      system.activationScripts.preActivation.text = lib.mkAfter handlerInstallScript;
    } else {
      system.activationScripts.fortProviderHandlers = {
        deps = [ "fortProviderConfig" ];
        text = handlerInstallScript;
      };
    }))

    # Generate systemd trigger units for capabilities with triggers.systemd
    # For each capability with systemd triggers:
    # 1. Create a oneshot service that runs the trigger logic
    # 2. Add OnSuccess= to each trigger unit to invoke our service
    (let
      # Filter to capabilities that have systemd triggers
      capsWithTriggers = lib.filterAttrs
        (name: cfg: cfg.triggers.systemd or [] != [])
        config.fort.host.capabilities;

      # Generate trigger services for each capability
      triggerServices = lib.mapAttrs' (capName: cfg:
        lib.nameValuePair "fort-provider-trigger-${capName}" {
          description = "Fort provider systemd trigger for ${capName}";
          # fort CLI must be on PATH: dispatchCallbacks shells out to it to
          # sign and POST consumer callbacks. Without this the trigger ran
          # the handler but every callback died on exec (ENOENT) and the
          # unit still exited 0 — renewals never reached consumers
          # (q-5118c7ed).
          path = [ fortCli ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${fortProvider}/bin/fort-provider --trigger ${capName}";
          };
        }
      ) capsWithTriggers;

      # Build a map of unit -> list of trigger services
      # This handles multiple capabilities that may trigger on the same unit
      unitToTriggers = lib.foldl' (acc: capName:
        let
          cfg = capsWithTriggers.${capName};
          triggerService = "fort-provider-trigger-${capName}.service";
        in lib.foldl' (acc': unit:
          let unitName = lib.removeSuffix ".service" unit;
          in acc' // {
            ${unitName} = (acc'.${unitName} or []) ++ [ triggerService ];
          }
        ) acc cfg.triggers.systemd
      ) {} (builtins.attrNames capsWithTriggers);

      # Generate OnSuccess drop-ins for trigger units
      triggerDropIns = lib.mapAttrs (unitName: triggerServices':
        { unitConfig.OnSuccess = triggerServices'; }
      ) unitToTriggers;

    # NixOS: systemd trigger units (darwin has no equivalent — triggers are NixOS-specific)
    in lib.mkIf (capsWithTriggers != {}) (if !isDarwin then {
      systemd.services = triggerServices // triggerDropIns;
    } else {}))

    # GC sweep timer for cleaning up orphaned provider state
    # Runs periodically to query consumers' needs and remove orphaned entries
    (let
      # Check if this host has any async capabilities (that need GC)
      hasAsyncCapabilities = builtins.any
        (cfg: cfg.mode == "async" || cfg.needsGC or false)
        (builtins.attrValues config.fort.host.capabilities);
    in lib.mkIf hasAsyncCapabilities (if !isDarwin then {
      # NixOS: systemd timer
      systemd.timers.fort-provider-gc = {
        description = "Fort provider garbage collection timer";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30m";    # First run 30m after boot
          OnUnitActiveSec = "1h"; # Then every hour
          RandomizedDelaySec = "5m"; # Spread out across cluster
        };
      };

      # GC service - queries consumers and cleans up orphaned state
      systemd.services.fort-provider-gc = {
        description = "Fort provider garbage collection";
        after = [ "network-online.target" "fort-provider.service" ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${fortProvider}/bin/fort-provider --gc";
        };

        # fort CLI needed for querying consumer needs endpoints
        path = [ fortCli pkgs.jq pkgs.coreutils ];
      };
    } else {
      # Darwin: launchd periodic GC
      launchd.daemons.fort-provider-gc = {
        serviceConfig = {
          Label = "network.gisi.fort.provider-gc";
          ProgramArguments = [ "${fortProvider}/bin/fort-provider" "--gc" ];
          StartInterval = 3600;  # Every hour
          StandardOutPath = "/var/log/fort-provider-gc.log";
          StandardErrorPath = "/var/log/fort-provider-gc.log";
          EnvironmentVariables = {
            PATH = "${lib.makeBinPath [ fortCli pkgs.jq pkgs.coreutils ]}:/usr/bin:/bin";
          };
        };
      };
    }))
  ];
}
