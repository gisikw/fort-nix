# Fort Agent Module
#
# Defines fort.needs and fort.capabilities options for the unified control plane.
# See docs/control-plane-design.md for architecture details.
#
# fort.needs.<type>.<name>: Declares what a host needs from capability providers
# fort.capabilities.<name>: Declares what capabilities a host exposes
#
{ rootManifest, cluster, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = rootManifest.fortConfig.settings.domain;
  hostName = config.networking.hostName;

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
  hostsJson = builtins.listToAttrs (map (h:
    let info = getHostPubkey h;
    in { name = info.name; value = { pubkey = info.pubkey; }; }
  ) (builtins.attrNames allHostManifests));

  fcgiSocket = "/run/fort-agent/fcgi.sock";

  # Derive RBAC from cluster topology
  # For each capability this host exposes, determine which hosts can call it
  deriveRbac = capabilities:
    lib.mapAttrs (capName: capCfg:
      # For now, allow all cluster hosts to call any capability
      # A more sophisticated version could use capCfg.satisfies to find
      # hosts that declare matching fort.needs.<satisfies>.* entries
      builtins.attrNames allHostManifests
    ) capabilities;

  # Need option type
  needOptions = {
    providers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Hostnames of capability providers to request from";
      example = [ "drhorrible" ];
    };

    request = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Request payload passed to the capability handler";
      example = { service = "outline"; };
    };

    store = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to store the response (null = don't store)";
      example = "/var/lib/fort/oidc/outline";
    };

    restart = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Systemd services to restart after successful fulfillment";
      example = [ "outline.service" ];
    };
  };

  # Capability option type
  capabilityOptions = {
    handler = lib.mkOption {
      type = lib.types.path;
      description = "Path to handler script";
    };

    needsGC = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether this capability needs garbage collection (adds handle wrapper)";
    };

    satisfies = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The need type this capability satisfies. Used for documentation and
        potentially for RBAC derivation (finding hosts that declare matching needs).
        If null, defaults to the capability name itself.

        Example: capability "oidc-register" might set satisfies = "oidc" to match
        fort.needs.oidc.* declarations.
      '';
      example = "oidc";
    };

    description = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Human-readable description of the capability";
    };
  };

  # Generate needs.json from all fort.needs declarations
  #
  # Structure: fort.needs.<capability>.<name> = { providers, request, store, restart }
  # The first key IS the capability name - no magic transformation.
  # Example: fort.needs.ssl-cert.wildcard calls the "ssl-cert" capability
  needsJson = let
    flattenNeeds = needs:
      lib.concatLists (lib.mapAttrsToList (capability:
        lib.mapAttrsToList (name: cfg: {
          id = "${capability}-${name}";
          inherit capability;
          inherit (cfg) providers request restart;
          store = cfg.store;
        })
      ) needs);
  in builtins.toJSON (flattenNeeds config.fort.needs);

  # Generate rbac.json from capabilities and topology
  rbacJson = builtins.toJSON (deriveRbac config.fort.capabilities);

  # Check if we have any needs or capabilities defined
  hasNeeds = config.fort.needs != { };
  hasCapabilities = config.fort.capabilities != { };

in
{
  options.fort = {
    needs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.submodule { options = needOptions; }));
      default = { };
      description = ''
        Declares what this host needs from capability providers.
        Structure: fort.needs.<capability>.<id> = { providers, request, store, restart }

        The first key is the capability to call. The second key is an arbitrary
        identifier for disambiguation - use "default" for singletons, or a
        descriptive id when you have multiple needs of the same capability.
        All actual parameters go in the request field.

        Examples:
          # Singleton - just use "default"
          fort.needs.ssl-cert.default = {
            providers = [ "drhorrible" ];
            store = "/var/lib/fort/ssl";
            restart = [ "nginx.service" ];
          };

          # Multiple of same capability - use descriptive ids
          fort.needs.oidc-register.outline = {
            providers = [ "drhorrible" ];
            request = { service = "outline"; };
            store = "/var/lib/fort/oidc/outline";
            restart = [ "outline.service" ];
          };
      '';
      example = {
        ssl-cert.default = {
          providers = [ "drhorrible" ];
          request = { };
          store = "/var/lib/fort/ssl";
          restart = [ "nginx.service" ];
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
          fort.capabilities.ssl-cert = {
            handler = ./handlers/ssl-cert;
            description = "Return cluster SSL certificates";
          };

          fort.capabilities.oidc-register = {
            handler = ./handlers/oidc-register;
            needsGC = true;  # Creates GC-able state
            description = "Register OIDC client in pocket-id";
          };
      '';
      example = {
        ssl-cert = {
          handler = ./handlers/ssl-cert;
          description = "Return cluster SSL certificates";
        };
      };
    };
  };

  config = lib.mkMerge [
    # Core agent infrastructure - always present on all hosts
    {
      # Generate hosts.json with peer public keys
      system.activationScripts.fortAgentHosts = {
        deps = [ ];
        text = ''
          install -d -m0755 /etc/fort-agent
          install -d -m0755 /etc/fort-agent/handlers
          install -Dm0644 ${pkgs.writeText "hosts.json" (builtins.toJSON hostsJson)} /etc/fort-agent/hosts.json
        '';
      };

      # Runtime directory for socket
      systemd.tmpfiles.rules = [
        "d /run/fort-agent 0755 root root -"
      ];

      # Socket activation for the FastCGI wrapper
      systemd.sockets.fort-agent = {
        description = "Fort Agent FastCGI Socket";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ fcgiSocket ];
        socketConfig = {
          SocketMode = "0660";
          SocketUser = "root";
          SocketGroup = "nginx";
        };
      };

      # The actual service (activated by socket)
      # Placeholder until fort-89e.2 implements the Go wrapper
      systemd.services.fort-agent = {
        description = "Fort Agent FastCGI Wrapper";
        requires = [ "fort-agent.socket" ];
        after = [ "fort-agent.socket" ];

        serviceConfig = {
          Type = "simple";
          # Placeholder: returns 501 Not Implemented for all requests
          ExecStart = pkgs.writeShellScript "fort-agent-placeholder" ''
            echo "Content-Type: application/json"
            echo "Status: 501 Not Implemented"
            echo ""
            echo '{"error": "fort-agent wrapper not yet implemented"}'
          '';
          StandardInput = "socket";
          StandardOutput = "socket";
        };
      };

      # Add /agent/* location to the host's nginx vhost
      # Extends the existing virtualHost from host-status aspect
      services.nginx.virtualHosts."${hostName}.fort.${domain}" = {
        locations."/agent/" = {
          extraConfig = ''
            # VPN-only access (cluster-internal)
            if ($is_vpn = 0) {
              return 444;
            }

            # FastCGI to the agent wrapper
            fastcgi_pass unix:${fcgiSocket};
            include ${pkgs.nginx}/conf/fastcgi_params;
            fastcgi_param SCRIPT_NAME $uri;
            fastcgi_param REQUEST_METHOD $request_method;
            fastcgi_param CONTENT_TYPE $content_type;
            fastcgi_param CONTENT_LENGTH $content_length;
            fastcgi_param QUERY_STRING $query_string;

            # Pass auth headers for signature verification
            fastcgi_param HTTP_X_FORT_ORIGIN $http_x_fort_origin;
            fastcgi_param HTTP_X_FORT_TIMESTAMP $http_x_fort_timestamp;
            fastcgi_param HTTP_X_FORT_SIGNATURE $http_x_fort_signature;
          '';
        };
      };
    }

    # Generate needs.json if any needs are declared
    (lib.mkIf hasNeeds {
      system.activationScripts.fortNeedsJson = {
        deps = [ "fortHostManifest" ];
        text = ''
          install -Dm0644 ${pkgs.writeText "needs.json" needsJson} /var/lib/fort/needs.json
        '';
      };
    })

    # Generate rbac.json and install handlers if capabilities are declared
    (lib.mkIf hasCapabilities {
      system.activationScripts.fortAgentConfig = {
        deps = [ "fortAgentHosts" ];
        text = ''
          # Install RBAC config
          install -Dm0644 ${pkgs.writeText "rbac.json" rbacJson} /etc/fort-agent/rbac.json

          # Install handler scripts
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: cfg: ''
            install -Dm0755 ${cfg.handler} /etc/fort-agent/handlers/${name}
          '') config.fort.capabilities)}
        '';
      };
    })
  ];
}
