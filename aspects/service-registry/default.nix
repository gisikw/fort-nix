{ hostManifest, rootManifest, cluster, ... }:
{ pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  hostFiles = builtins.readDir cluster.hostsDir;
  hosts = builtins.mapAttrs (name: _: import (cluster.hostsDir + "/" + name + "/manifest.nix")) hostFiles;
  beacons = builtins.filter (h: builtins.elem "beacon" h.roles) (builtins.attrValues hosts);
  beaconHost = (builtins.head beacons).hostName;
in
{
  systemd.timers."fort-service-registry" = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnUnitActiveSec = "10m";
  };

  systemd.services."fort-service-registry" = {
    path = with pkgs; [
      ruby
      tailscale
      openssh
      bind.dnsutils
      iproute2
    ];
    serviceConfig = {
      ExecStart = "${pkgs.ruby}/bin/ruby ${./registry.rb}";
      Environment = [
        "DOMAIN=${domain}"
        "FORGE_HOST=${hostManifest.hostName}"
        "BEACON_HOST=${beaconHost}"
      ];
    };
  };
}
