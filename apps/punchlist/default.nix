{ ... }:
{ pkgs, ... }:
let
  serverDir = "/home/dev/Projects/punchlist-server";
  dataDir = "/var/lib/punchlist";
  dataFile = "${dataDir}/items.json";

  fixpermsScript = pkgs.writeShellScript "punchlist-fixperms" ''
    # Ensure directory has correct ownership and setgid
    chown punchlist:users ${dataDir}
    chmod 2775 ${dataDir}

    # If data file exists with wrong ownership, fix it
    if [ -f ${dataFile} ]; then
      chown punchlist:users ${dataFile}
      chmod 0660 ${dataFile}
    fi
  '';
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

  # Data directory with setgid - files created inside inherit 'users' group
  # Combined with 0660 mode and UMask 0007, both punchlist and dev can read/write
  systemd.tmpfiles.rules = [
    "d ${dataDir} 2775 punchlist users -"
  ];

  systemd.services.punchlist = {
    description = "Punchlist - simple todo app";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      User = "punchlist";
      Group = "users";
      UMask = "0007";  # Files created are 0660 (user+group rw)
      WorkingDirectory = dataDir;
      ExecStart = "${serverDir}/punchlist -addr 127.0.0.1:8765 -data ${dataDir}/items.json";
      Restart = "on-failure";
      RestartSec = 5;

      # Fix ownership on start - "+" prefix runs as root
      ExecStartPre = "+${fixpermsScript}";
    };
  };

  # Watch for file changes and fix permissions immediately
  # This handles atomic saves (write temp + rename) by dev user
  systemd.paths.punchlist-fixperms = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = dataDir;  # Watch directory for any changes
      Unit = "punchlist-fixperms.service";
    };
  };

  systemd.services.punchlist-fixperms = {
    description = "Fix punchlist data file permissions";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = fixpermsScript;
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
