# Service exposure bookkeeping (q-d9cba37c)
#
# Everything derived from fort.cluster.services that is NOT nginx or auth:
# the host manifest written for service discovery, and the auto-generated
# discovery needs (public proxy, headscale DNS, coredns DNS).
{ rootManifest, cluster, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = rootManifest.fortConfig.settings.domain;

  inherit (import ./service-lib.nix) subdomainOf;

  # Discover beacon host for proxy needs
  beaconHost = let
    hostFiles = builtins.readDir cluster.hostsDir;
    hosts = builtins.mapAttrs (name: _: import (cluster.hostsDir + "/" + name + "/manifest.nix")) hostFiles;
    beacons = builtins.filter (h: builtins.elem "beacon" h.roles) (builtins.attrValues hosts);
  in if beacons != [] then (builtins.head beacons).hostName else null;

  # Discover forge host for LAN DNS needs
  forgeHost = let
    hostFiles = builtins.readDir cluster.hostsDir;
    hosts = builtins.mapAttrs (name: _: import (cluster.hostsDir + "/" + name + "/manifest.nix")) hostFiles;
    forges = builtins.filter (h: builtins.elem "forge" h.roles) (builtins.attrValues hosts);
  in if forges != [] then (builtins.head forges).hostName else null;

  # Check if this host is the proxy provider (beacon)
  isProxyProvider = beaconHost == config.networking.hostName;

  # Get services that need public proxy configuration
  publicServices = builtins.filter (svc: svc.visibility == "public") config.fort.cluster.services;

  # Get services that need LAN DNS (non-vpn visibility)
  lanDnsServices = builtins.filter (svc: svc.visibility != "vpn") config.fort.cluster.services;
in
{
  config = lib.mkMerge [
    # Write unified host manifest for service discovery
    {
      system.activationScripts.fortHostManifest.text = let
        hostManifestJson = builtins.toFile "host-manifest.json"
          ((import ./service-lib.nix).hostManifestContentFor config);
      in ''
        install -Dm0644 ${hostManifestJson} /var/lib/fort/host-manifest.json
      '';
    }

    # Proxy needs - auto-generated for public services
    # Each public service gets a proxy need to configure beacon's nginx
    (lib.mkIf (publicServices != [] && !isProxyProvider && beaconHost != null) {
      fort.host.needs.proxy = lib.listToAttrs (map (svc:
        let
          subdomain = subdomainOf svc;
          fqdn = "${subdomain}.${domain}";
        in {
          name = svc.name;
          value = {
            from = beaconHost;
            request = {
              inherit fqdn;
            };
            nag = "1h";
            # No handler - side-effect-only need
          };
        }
      ) publicServices);
    })

    # DNS (Headscale) needs - auto-generated for all services
    # Each service gets a dns-headscale need so it can be resolved over the VPN mesh
    (lib.mkIf (config.fort.cluster.services != [] && beaconHost != null) {
      fort.host.needs.dns-headscale = lib.listToAttrs (map (svc:
        let
          subdomain = subdomainOf svc;
          fqdn = "${subdomain}.${domain}";
        in {
          name = svc.name;
          value = {
            from = beaconHost;
            request = {
              inherit fqdn;
            };
            nag = "1h";
            # No handler - side-effect-only need (provider writes extra-records.json)
          };
        }
      ) config.fort.cluster.services);
    })

    # DNS (CoreDNS) needs - auto-generated for non-vpn services
    # Each non-vpn service gets a dns-coredns need so it can be resolved on the LAN
    (lib.mkIf (lanDnsServices != [] && forgeHost != null) {
      fort.host.needs.dns-coredns = lib.listToAttrs (map (svc:
        let
          subdomain = subdomainOf svc;
          fqdn = "${subdomain}.${domain}";
        in {
          name = svc.name;
          value = {
            from = forgeHost;
            request = {
              inherit fqdn;
            };
            nag = "1h";
            # No handler - side-effect-only need (provider writes custom.conf)
          };
        }
      ) lanDnsServices);
    })
  ];
}
