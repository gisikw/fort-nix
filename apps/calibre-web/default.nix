{ subdomain ? "ebooks", ... }:
{ config, lib, pkgs, ... }:
let
  stateDir = "/var/lib/calibre-web";
in
{
  users.groups = {
    media = lib.mkDefault { };
    calibre-web = { };
  };

  users.users.calibre-web = {
    isSystemUser = true;
    group = "calibre-web";
    extraGroups = [ "media" ];
    home = stateDir;
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 calibre-web calibre-web -"
  ];

  systemd.services.calibre-web = {
    description = "Calibre Web";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "zfs-late-import.service" ];

    serviceConfig = {
      User = "calibre-web";
      Group = "calibre-web";
      WorkingDirectory = stateDir;
      RuntimeDirectory = "calibre-web";
      Restart = "on-failure";
      RestartSec = 10;
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.calibre-web}/bin/calibre-web"
        "-p ${stateDir}/app.db"
        "-g ${stateDir}/gdrive.db"
        "-i 127.0.0.1"
        "-o ${stateDir}/calibre-web.log"
      ];
      Environment = [
        "CALIBRE_DBPATH=${stateDir}"
        "CALIBRE_LIBRARY=/media/ebooks/metadata.db"
      ];
    };

    path = [
      pkgs.calibre
      pkgs.util-linux
      pkgs.coreutils
    ];
  };

  fort.cluster.services = [
    {
      name = "calibre-web";
      subdomain = subdomain;
      port = 8083;
    }
  ];
}
