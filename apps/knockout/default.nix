{ ... }:
{ pkgs, ... }:
{
  systemd.services.knockout = {
    description = "Knockout - ko HTTP server and SSE event stream";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "users";
      WorkingDirectory = "/home/dev/Projects/exocortex";
      ExecStart = "/run/managed-bin/ko serve --port 19876";
      Restart = "on-failure";
      RestartSec = 5;

      Environment = "PATH=${pkgs.git}/bin:/run/managed-bin:/run/current-system/sw/bin";
    };
  };
}
