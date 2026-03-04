{ ... }:
{ pkgs, ... }:

let
  port = 9878;
  homeDir = "/home/dev";
  findingsDir = "${homeDir}/Projects/research/findings";
in
{
  systemd.services.research = {
    description = "Research findings server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "users";
      WorkingDirectory = "${homeDir}/Projects/research";
      ExecStart = "${homeDir}/Projects/research/research-server --dir ${findingsDir} --port ${toString port}";
      Restart = "always";
      RestartSec = 5;
    };
  };

  fort.cluster.services = [{
    name = "research";
    inherit port;
    visibility = "public";
    sso = {
      mode = "oidc";
      vpnBypass = true;
    };
  }];
}
