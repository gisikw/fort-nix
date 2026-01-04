{ subdomain ? "notes", dataDir ? null, ... }:
{ lib, pkgs, ... }:
let
  defaultStateDir = "/var/lib/silverbullet";
  effectiveDataDir = if dataDir != null then dataDir else defaultStateDir;
  useDefaultDir = dataDir == null;
in
{
  users.groups.silverbullet = { };

  users.users.silverbullet = {
    isSystemUser = true;
    group = "silverbullet";
    home = defaultStateDir;
  };

  # Only create default state directory if no custom dataDir specified
  systemd.tmpfiles.rules = lib.optionals useDefaultDir [
    "d ${defaultStateDir} 0750 silverbullet silverbullet -"
  ];

  systemd.services.silverbullet = {
    description = "SilverBullet PKM";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      User = "silverbullet";
      Group = "silverbullet";
      WorkingDirectory = effectiveDataDir;
      UMask = "0002";  # Group-writable files for shared access
      Restart = "on-failure";
      RestartSec = 10;
      ExecStart = "${lib.getExe pkgs.silverbullet}";
      Environment = [
        "SB_FOLDER=${effectiveDataDir}"
        "SB_HOSTNAME=127.0.0.1"
        "SB_PORT=3033"
      ];
    };
  };

  fortCluster.exposedServices = [
    {
      name = "silverbullet";
      subdomain = subdomain;
      port = 3033;
      visibility = "public";
      sso = {
        mode = "gatekeeper";
      };
    }
  ];
}
