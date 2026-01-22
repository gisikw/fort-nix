{ ... }:
{ pkgs, lib, ... }:
let
  punchlist = import ../../pkgs/punchlist { inherit pkgs; };
  dataDir = "/var/lib/punchlist";
in
{
  # Run as punchlist user in users group so dev can also access the file
  users.groups.punchlist = { };
  users.users.punchlist = {
    isSystemUser = true;
    group = "punchlist";
    extraGroups = [ "users" ];
    home = dataDir;
  };

  # Data directory - group writable so dev user can edit items.json
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0775 punchlist users -"
  ];

  systemd.services.punchlist = {
    description = "Punchlist - simple todo app";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      User = "punchlist";
      Group = "users";
      UMask = "0002";  # Files created are group-writable
      WorkingDirectory = dataDir;
      ExecStart = "${lib.getExe punchlist} -addr 127.0.0.1:8765 -data ${dataDir}/items.json";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  fort.cluster.services = [
    {
      name = "punchlist";
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
