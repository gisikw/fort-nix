# Shared fort.cluster option declarations used by both NixOS and darwin platforms.
# The NixOS-specific config (nginx, systemd services, etc.) lives in fort.nix.
{ rootManifest, cluster, ... }:
{ config, lib, pkgs, ... }:
{
  options.fort.cluster = lib.mkOption {
    type = lib.types.submodule {
      freeformType = lib.types.attrsOf lib.types.anything;
      options = {
        services = lib.mkOption {
          type =
            with lib.types;
            listOf (submodule {
              options = {
                name = lib.mkOption {
                  type = str;
                  description = "Logical service name (used for default subdomain).";
                };

                subdomain = lib.mkOption {
                  type = nullOr str;
                  default = null;
                  description = "Optional subdomain override.";
                };

                port = lib.mkOption {
                  type = nullOr int;
                  default = null;
                  description = "Internal port where the service listens. Required unless staticRoot is set.";
                };

                staticRoot = lib.mkOption {
                  type = nullOr str;
                  default = null;
                  description = "If set, serve static files from this path instead of proxying to a port.";
                };

                inEgressNamespace = lib.mkOption {
                  type = bool;
                  default = false;
                  description = "Whether this service runs inside the egress-vpn namespace";
                };

                maxBodySize = lib.mkOption {
                  type = nullOr str;
                  default = null;
                  description = "nginx client_max_body_size for this service";
                };

                visibility = lib.mkOption {
                  type = enum [ "vpn" "local" "public" ];
                  default = "vpn";
                  description = "The visibility level for this service.";
                };

                lanDirect = lib.mkOption {
                  type = bool;
                  default = false;
                  description = ''
                    If true, open this service's port directly to the LAN prefix,
                    bypassing nginx entirely (no TLS, no vhost, no token wall).

                    Intended for appliance clients that cannot tolerate the normal
                    ingress path — e.g. a kiosk tablet whose WebView stalls on TLS
                    handshake or captive-portal checks. The firewall rule is scoped
                    to the LAN source prefix, so this does NOT expose the port to
                    the VPN mesh or to any other network.

                    Only meaningful alongside sso.localBypass: a LAN client reaching
                    the port directly gets whatever the service itself enforces.
                  '';
                };

                sso = lib.mkOption {
                  type = submodule {
                    options = {
                      mode = lib.mkOption {
                        type = enum [ "none" "oidc" "headers" "basicauth" "gatekeeper" "token" "identity" ];
                        default = "none";
                        description = "SSO handling mode for this service.";
                      };

                      restart = lib.mkOption {
                        type = nullOr str;
                        default = null;
                        description = "Name of the systemd service to restart after OIDC credentials are delivered.";
                      };

                      groups = lib.mkOption {
                        type = listOf str;
                        default = [ ];
                        description = "Optional list of allowed LDAP/SSO groups.";
                      };

                      vpnBypass = lib.mkOption {
                        type = bool;
                        default = false;
                        description = "If true, requests from the VPN bypass authentication entirely.";
                      };

                      localBypass = lib.mkOption {
                        type = bool;
                        default = false;
                        description = "If true, requests from the LAN bypass authentication entirely.";
                      };
                    };
                  };
                  default = { };
                };

                health = lib.mkOption {
                  type = submodule {
                    options = {
                      enabled = lib.mkOption {
                        type = bool;
                        default = true;
                        description = "Whether this service should be monitored by Gatus.";
                      };

                      endpoint = lib.mkOption {
                        type = str;
                        default = "/";
                        description = "Health check endpoint path.";
                      };

                      interval = lib.mkOption {
                        type = str;
                        default = "5m";
                        description = "Health check interval.";
                      };

                      conditions = lib.mkOption {
                        type = listOf str;
                        default = [ "[STATUS] == 200" "[RESPONSE_TIME] < 5000" ];
                        description = "Gatus condition expressions for health checks.";
                      };
                    };
                  };
                  default = { };
                };
              };
            });
          default = [ ];
          description = "List of service exposure declarations.";
        };
      };
    };
    default = { };
    description = "Cluster-level configuration and service exposure registry.";
  };
}
