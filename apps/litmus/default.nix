{ ... }:
{ pkgs, ... }:

let
  port = 8700;
in
{
  systemd.services.litmus = {
    description = "Litmus - Agentic workflow eval harness";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "users";
      WorkingDirectory = "/home/dev/Projects/litmus";
      ExecStart = "/run/managed-bin/litmus serve --port ${toString port}";
      Restart = "on-failure";
      RestartSec = 5;

      Environment = "PATH=${pkgs.git}/bin:/run/managed-bin:/run/current-system/sw/bin";
    };
  };

  fort.cluster.services = [
    {
      name = "litmus";
      inherit port;
      visibility = "public";
      sso = {
        mode = "gatekeeper";
        vpnBypass = true;
      };
    }
  ];
}
