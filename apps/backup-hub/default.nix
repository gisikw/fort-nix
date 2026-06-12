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
        echo "Repository initialized."
      else
        echo "Repository already initialized."
      fi
      # Ensure all repo files are owned by restic (fixes drift from
      # services that previously ran as root, e.g. prune)
      chown -R restic:restic "${dataDir}"
    '';
  };

  sops.secrets.restic-password = {
    sopsFile = ../../aspects/backup-client/restic-password.sops;
    format = "binary";
    mode = "0400";
    owner = "restic";
  };

  # Centralized prune — runs on the hub so clients never contend for locks.
  # Scheduled after the backup window (clients run at midnight + up to 1h jitter).
  systemd.timers.restic-prune = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = true;
    };
  };

  systemd.services.restic-prune = {
    description = "Restic repository prune";
    after = [ "restic-rest-server.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "restic";
      Group = "restic";
    };
    path = [ pkgs.restic ];
    script = ''
      restic -r "${dataDir}" \
        --password-file ${config.sops.secrets.restic-password.path} \
        forget \
        --keep-daily 7 \
        --keep-weekly 4 \
        --keep-monthly 6 \
        --prune
    '';
  };

  fort.cluster.services = [
    {
      name = "backup";
      inherit port;
      visibility = "vpn";
      sso.mode = "none";
      maxBodySize = "100m";
    }
  ];
}
