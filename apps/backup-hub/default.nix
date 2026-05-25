{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  port = 8000;
  dataDir = "/var/lib/restic-repos";
in
{
  services.restic.server = {
    enable = true;
    listenAddress = "127.0.0.1:${toString port}";
    inherit dataDir;
    appendOnly = true;
    prometheus = true;
    extraFlags = [ "--no-auth" ];
  };

  # Initialize the restic repository if it doesn't exist yet.
  # Clients cannot back up until the repo is initialized.
  systemd.services.restic-repo-init = {
    after = [ "restic-rest-server.service" ];
    requires = [ "restic-rest-server.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.restic ];
    script = ''
      if [ ! -f "${dataDir}/config" ]; then
        echo "Initializing restic repository..."
        restic -r "${dataDir}" init --password-file ${config.sops.secrets.restic-password.path}
        chown -R restic:restic "${dataDir}"
        echo "Repository initialized."
      else
        echo "Repository already initialized."
      fi
    '';
  };

  sops.secrets.restic-password = {
    sopsFile = ../../aspects/backup-client/restic-password.sops;
    format = "binary";
    mode = "0400";
  };

  fort.cluster.services = [
    {
      name = "backup";
      inherit port;
      visibility = "vpn";
      sso.mode = "none";
    }
  ];
}
