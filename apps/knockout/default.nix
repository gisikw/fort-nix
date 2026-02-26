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
      ExecStart = "/home/dev/.local/bin/ko serve --port 9877";
      Restart = "on-failure";
      RestartSec = 5;

      Environment = "PATH=${pkgs.git}/bin:/home/dev/.local/bin:/run/current-system/sw/bin";
    };
  };

  fort.cluster.services = [
    {
      name = "knockout";
      port = 9877;
      visibility = "public";
      sso = {
        mode = "token";
        vpnBypass = true;
      };
    }
  ];
}
