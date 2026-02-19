{ ... }:
{ pkgs, ... }:
let
  serverDir = "/home/dev/Projects/punchlist-server";
in
{
  systemd.services.punchlist = {
    description = "Punchlist - ko adapter for mobile/web task management";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "users";
      ExecStart = "${serverDir}/punchlist -addr 127.0.0.1:8765";
      Restart = "on-failure";
      RestartSec = 5;

      # ko binary and git need to be on PATH
      Environment = "PATH=${pkgs.git}/bin:/home/dev/.local/bin:/run/current-system/sw/bin";
    };
  };

  fort.cluster.services = [
    {
      name = "punchlist";
      subdomain = "punch";
      port = 8765;
      visibility = "public";
      sso = {
        mode = "gatekeeper";
        vpnBypass = true;
        groups = [ "admin" ];
      };
    }
  ];
}
