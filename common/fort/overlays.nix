# Fort Overlays Module
#
# Runtime-deferred service composition. Each project ships an overlay.nix
# alongside its binary. The overlay manager polls a registry, fetches new
# versions from Attic, evaluates overlay.nix with host-provided config,
# generates systemd units, and manages health checks with rollback.
#
# Overlays are declared as plain data in the host manifest (like apps/aspects):
#
#   overlays = {
#     knockout = {
#       package = "infra/knockout";
#       config = { port = "19876"; };
#       expose = {
#         port = 19876;
#         visibility = "public";
#         sso = { mode = "gatekeeper"; vpnBypass = true; };
#       };
#     };
#   };
#
{ rootManifest, hostManifest, cluster, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = rootManifest.fortConfig.settings.domain;
  overlays = hostManifest.overlays or {};

  # Discover the host running the overlay-registry app
  hostFiles = builtins.readDir cluster.hostsDir;
  allHostManifests = builtins.mapAttrs
    (name: _: import (cluster.hostsDir + "/" + name + "/manifest.nix"))
    hostFiles;
  registryHost = let
    hosts = builtins.filter
      (h: builtins.elem "overlay-registry" (h.apps or []))
      (builtins.attrValues allHostManifests);
  in
    if hosts != [] then (builtins.head hosts).hostName else null;

  registryUrl =
    if registryHost != null
    then "https://overlay-registry.${domain}"
    else null;

  hasOverlays = overlays != {} && registryUrl != null;

  fort-overlay-manager = import ../../pkgs/fort-overlay-manager { inherit pkgs; };

  # Normalize overlay config: fill in defaults
  normalizeOverlay = name: ov: {
    package = ov.package;
    config = ov.config or {};
    secrets = ov.secrets or {};
    paths = ov.paths or {};
    expose = ov.expose or null;
    enabled = ov.enabled or true;
  };

  normalizedOverlays = builtins.mapAttrs normalizeOverlay overlays;

  # Build the config JSON that the manager reads
  overlayConfigs = builtins.mapAttrs (name: ov: {
    package = ov.package;
    config = ov.config // (builtins.mapAttrs (secretName: _:
      "%SECRET:/run/agenix/overlay-${name}-${secretName}%"
    ) ov.secrets);
    enabled = ov.enabled;
  }) normalizedOverlays;

  managerConfig = {
    registryUrl = registryUrl;
    pollInterval = "5m";
    stateDir = "/var/lib/fort-overlay-manager";
    binDir = "/run/overlays/bin";
    overlays = overlayConfigs;
  };

  configFile = pkgs.writeText "overlays.json" (builtins.toJSON managerConfig);

  # Collect secrets from all overlays
  allSecrets = lib.foldlAttrs (acc: name: ov:
    acc // (builtins.mapAttrs' (secretName: secretPath: {
      name = "overlay-${name}-${secretName}";
      value = {
        file = secretPath;
        path = "/run/agenix/overlay-${name}-${secretName}";
      };
    }) ov.secrets)
  ) {} normalizedOverlays;

  # Generate fort.cluster.services from overlay expose declarations
  exposedServices = lib.foldlAttrs (acc: name: ov:
    if ov.expose != null then
      acc ++ [{
        name = name;
        subdomain = ov.expose.subdomain or null;
        port = ov.expose.port;
        visibility = ov.expose.visibility or "vpn";
        sso = ov.expose.sso or {};
      }]
    else acc
  ) [] normalizedOverlays;

in
{
  config = lib.mkIf hasOverlays (lib.mkMerge [
    # Service exposure from overlay declarations
    { fort.cluster.services = exposedServices; }

    # Secrets from overlay declarations
    (lib.mkIf (allSecrets != {}) {
      age.secrets = allSecrets;
    })

    # Refresh capability for on-demand overlay checks
    {
      fort.host.capabilities.refresh = {
        handler = pkgs.writeShellScript "handle-refresh" ''
          set -euo pipefail
          input=$(${pkgs.coreutils}/bin/cat)
          overlay=$(echo "$input" | ${pkgs.jq}/bin/jq -r '.overlay // empty')
          if [ -n "$overlay" ]; then
            echo "Refreshing overlay: $overlay" >&2
            ${fort-overlay-manager}/bin/fort-overlay-manager check --overlay "$overlay"
          else
            echo "Refreshing all overlays" >&2
            ${fort-overlay-manager}/bin/fort-overlay-manager check
          fi
          echo '{"status":"ok"}'
        '';
        mode = "rpc";
        description = "Trigger overlay refresh";
      };
    }

    # State directory and bin directory
    {
      systemd.tmpfiles.rules = [
        "d /var/lib/fort-overlay-manager 0755 root root -"
        "d /run/overlays 0755 root root -"
        "d /run/overlays/bin 0755 root root -"
      ];
    }

    # Manager config file
    { environment.etc."fort/overlays.json".source = configFile; }

    # Boot service: regenerate systemd units from state dir on startup
    {
      systemd.services.fort-overlay-manager-boot = {
        description = "Fort overlay manager - regenerate units on boot";
        after = [ "local-fs.target" ];
        before = [ "multi-user.target" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${fort-overlay-manager}/bin/fort-overlay-manager boot";
        };
      };
    }

    # Timer-driven check service
    {
      systemd.services.fort-overlay-manager-check = {
        description = "Fort overlay manager - check for updates";
        after = [ "network-online.target" "fort-overlay-manager-boot.service" ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${fort-overlay-manager}/bin/fort-overlay-manager check";
        };
      };

      systemd.timers.fort-overlay-manager-check = {
        description = "Fort overlay manager - periodic check";
        wantedBy = [ "timers.target" ];
        after = [ "fort-overlay-manager-boot.service" ];

        timerConfig = {
          OnBootSec = "1m";
          OnUnitActiveSec = "5m";
          RandomizedDelaySec = "30s";
        };
      };
    }

    # Add /run/overlays/bin to PATH
    {
      environment.extraInit = ''
        export PATH="/run/overlays/bin:$PATH"
      '';
    }
  ]);
}
