{ rootManifest, cluster, ... }:
{ pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;

  # Get list of hosts from cluster
  hostFiles = builtins.readDir cluster.hostsDir;
  hostNames = builtins.attrNames hostFiles;

  # Build the Go binary
  uploadGateway = pkgs.buildGoModule {
    pname = "upload-gateway";
    version = "0.1.0";
    src = ./.;
    vendorHash = null;

    meta = with pkgs.lib; {
      description = "Web UI for uploading files to fort hosts";
      license = licenses.mit;
      platforms = platforms.linux;
    };
  };

  port = 8090;
in
{
  systemd.services.upload-gateway = {
    description = "Upload Gateway";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      UPLOAD_HOSTS = lib.concatStringsSep "," hostNames;
      UPLOAD_DOMAIN = domain;
      UPLOAD_BIND = "127.0.0.1:${toString port}";
    };

    serviceConfig = {
      Type = "simple";
      ExecStart = "${uploadGateway}/bin/upload-gateway";
      Restart = "always";
      RestartSec = "5s";

      # Security hardening
      DynamicUser = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };

  fort.cluster.services = [
    {
      name = "upload-gateway";
      subdomain = "upload";
      inherit port;
      visibility = "public";
      maxBodySize = "500M";
      sso = {
        mode = "gatekeeper";
        groups = [ "admin" ];
        vpnBypass = true;
      };
    }
  ];
}
