{ ... }:
{ config, pkgs, lib, ... }:
let
  overlay-registry = pkgs.buildGoModule {
    pname = "overlay-registry";
    version = "0.1.0";
    src = ./.;
    vendorHash = null;
  };
in
{
  systemd.services.overlay-registry = {
    description = "Fort overlay registry";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${overlay-registry}/bin/overlay-registry";
      Restart = "on-failure";
      RestartSec = "5s";
      StateDirectory = "overlay-registry";
      Environment = [
        "REGISTRY_DATA_FILE=/var/lib/overlay-registry/registry.json"
        "LISTEN_ADDR=127.0.0.1:9480"
      ];
    };
  };

  fort.cluster.services = [{
    name = "overlay-registry";
    port = 9480;
    visibility = "vpn";
    sso.mode = "none";
  }];
}
