{ ... }:
{ pkgs, ... }:

let
  port = 8090;
in
{
  systemd.services.treeline = {
    description = "Treeline - Shelly relay control panel";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      DynamicUser = true;
      ExecStart = "${pkgs.python3}/bin/python3 ${./server.py}";
      Restart = "on-failure";
      RestartSec = 5;

      Environment = [
        "PORT=${toString port}"
        "SHELLY_HOST=192.168.68.68"
      ];
    };
  };

  fort.cluster.services = [
    {
      name = "treeline";
      inherit port;
      visibility = "public";
      sso = {
        mode = "gatekeeper";
        vpnBypass = true;
      };
    }
  ];
}
