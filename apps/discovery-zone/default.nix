{ ... }:
{ pkgs, config, ... }:

let
  port = 9878;
  homeDir = "/home/dev";
  findingsDir = "${homeDir}/Projects/discovery-zone/findings";
in
{
  systemd.services.discovery-zone = {
    description = "Discovery Zone findings server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "users";
      WorkingDirectory = "${homeDir}/Projects/discovery-zone";
      ExecStart = "${homeDir}/Projects/discovery-zone/discovery-zone --dir ${findingsDir} --port ${toString port}";
      Restart = "always";
      RestartSec = 5;

      Environment = "PATH=/run/overlays/bin:/run/managed-bin:${homeDir}/.local/bin:/run/current-system/sw/bin";
    };
  };

  fort.cluster.services = [{
    name = "dz";
    inherit port;
    visibility = "public";
    sso = {
      mode = "oidc";
      vpnBypass = true;
    };
  }];
}
