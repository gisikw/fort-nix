{ ... }:
{ lib, pkgs, ... }:
let
  stateDir = "/var/lib/silverbullet";
in
{
  users.groups.silverbullet = { };

  users.users.silverbullet = {
    isSystemUser = true;
    group = "silverbullet";
    home = stateDir;
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 silverbullet silverbullet -"
  ];

  systemd.services.silverbullet = {
    description = "SilverBullet PKM";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      User = "silverbullet";
      Group = "silverbullet";
      WorkingDirectory = stateDir;
      Restart = "on-failure";
      RestartSec = 10;
      ExecStart = "${lib.getExe pkgs.silverbullet}";
      Environment = [
        "SB_FOLDER=${stateDir}"
        "SB_HOSTNAME=127.0.0.1"
        "SB_PORT=3033"
      ];
    };
  };

  fortCluster.exposedServices = [
    {
      name = "silverbullet";
      subdomain = "notes";
      port = 3033;
    }
  ];
}
