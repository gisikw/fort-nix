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

    path = config.environment.systemPackages ++ [ "${homeDir}/.local" ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "users";
      WorkingDirectory = "${homeDir}/Projects/discovery-zone";
      ExecStart = "${homeDir}/Projects/discovery-zone/discovery-zone --dir ${findingsDir} --port ${toString port}";
      Restart = "always";
      RestartSec = 5;
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
