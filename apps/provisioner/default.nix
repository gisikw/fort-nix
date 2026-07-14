{ cluster, ... }:
{ config, pkgs, lib, ... }:
let
  provisioner = import ../../pkgs/provisioner { inherit pkgs; };
  prepareClaim = pkgs.writeShellApplication {
    name = "fort-prepare-claim";
    runtimeInputs = [ pkgs.jq pkgs.nix pkgs.python3 pkgs.gnutar pkgs.gzip pkgs.sops pkgs.ssh-to-age ];
    text = builtins.readFile ../../provisioning/prepare-claim.sh;
  };
  domain = cluster.manifest.fortConfig.settings.domain;
  pendingTargets = builtins.fromJSON (builtins.readFile ../../provisioning/targets.json);
  hostDirs = builtins.readDir cluster.hostsDir;
  configuredTargets = lib.mapAttrsToList (name: _: let
    manifest = import (cluster.hostsDir + "/${name}/manifest.nix");
    device = import (cluster.devicesDir + "/${manifest.device}/manifest.nix");
  in { host = name; profile = device.profile; })
    (lib.filterAttrs (_: type: type == "directory") hostDirs);
  pendingNames = map (t: t.host) pendingTargets;
  targets = pendingTargets ++ builtins.filter (t: !(builtins.elem t.host pendingNames)) configuredTargets;
  registry = pkgs.writeText "provision-targets.json" (builtins.toJSON targets);
in {
  sops.secrets.provision-bootstrap-secret = {
    sopsFile = ./bootstrap-secret.sops;
    format = "binary";
    path = "/var/lib/fort-provisioner/bootstrap-secret";
    mode = "0400";
  };

  systemd.services.fort-provisioner = {
    description = "Fort unattended provisioning broker";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${provisioner}/bin/fort-provisioner";
      Restart = "on-failure";
      StateDirectory = "fort-provisioner";
      UMask = "0077";
      Environment = [
        "LISTEN_ADDR=127.0.0.1:9480"
        "REGISTRY_PATH=${registry}"
        "BOOTSTRAP_SECRET_FILE=/var/lib/fort-provisioner/bootstrap-secret"
        "STATE_PATH=/var/lib/fort-provisioner/state.json"
        "COMPLETIONS_DIR=/var/lib/fort-provisioner/completions"
        "PREPARE_COMMAND=${prepareClaim}/bin/fort-prepare-claim"
      ];
    };
  };

  fort.cluster.services = [{
    name = "provisioner";
    subdomain = "provision";
    port = 9480;
    visibility = "public";
    maxBodySize = "3m";
    sso = { mode = "identity"; groups = [ "admin" ]; };
  }];

  # Machine endpoints authenticate themselves with the fleet secret / claim token,
  # bypassing browser SSO while the dashboard remains identity-protected.
  services.nginx.virtualHosts."provision.${domain}" = {
    locations."= /activate" = { proxyPass = "http://127.0.0.1:9480"; };
    locations."~ ^/bootstrap/" = { proxyPass = "http://127.0.0.1:9480"; };
    locations."~ ^/complete/" = { proxyPass = "http://127.0.0.1:9480"; extraConfig = "client_max_body_size 3m;"; };
  };
}
