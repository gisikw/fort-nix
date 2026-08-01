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
  lanIpv4Prefix = rootManifest.fortConfig.settings.lan.ipv4Prefix;

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

  # Services opting into a direct LAN port (nginx bypass). See lanDirect in
  # common/fort-options.nix.
  lanDirectServices = builtins.filter
    (svc: (svc.lanDirect or false) && svc.port != null)
    config.fort.cluster.services;
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

    # Direct LAN port exposure (nginx bypass) for services with lanDirect.
    #
    # Scoped to the LAN source prefix rather than a global allowedTCPPorts:
    # a global allowance would also expose the port to the VPN mesh and to
    # anything else that routes to this host, which for a localBypass service
    # means exposing it past its own auth wall. The source match is the whole
    # point of this block — do not "simplify" it into allowedTCPPorts.
    #
    # Plain `iptables`, never the `ip46tables` helper: this is an IPv4 prefix,
    # and feeding it to ip6tables would fail the firewall unit at activation.
    (lib.mkIf (lanDirectServices != []) {
      networking.firewall.extraCommands = lib.concatMapStrings (svc: ''
        iptables -w -A nixos-fw -p tcp -s ${lanIpv4Prefix} --dport ${toString svc.port} \
          -m comment --comment "fort-lan-direct:${svc.name}" -j nixos-fw-accept
      '') lanDirectServices;
    })
  ];
}
