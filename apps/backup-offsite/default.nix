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
      chown -R restic:restic "${dataDir}"
    '';
  };

  sops.secrets.restic-password = {
    sopsFile = ../../aspects/backup-client/restic-password.sops;
    format = "binary";
    mode = "0400";
    owner = "restic";
  };

  # Prune with same retention as the primary hub.
  systemd.timers.restic-prune = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 06:00:00";
      Persistent = true;
    };
  };

  systemd.services.restic-prune = {
    description = "Restic repository prune (offsite)";
    after = [ "restic-rest-server.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "restic";
      Group = "restic";
    };
    path = [ pkgs.restic ];
    script = ''
      echo "Removing stale restic locks before prune..."
      restic -r "${dataDir}" \
        --password-file ${config.sops.secrets.restic-password.path} \
        unlock

      restic -r "${dataDir}" \
        --password-file ${config.sops.secrets.restic-password.path} \
        forget \
        --retry-lock 30m \
        --keep-daily 7 \
        --keep-weekly 4 \
        --keep-monthly 6 \
        --prune
    '';
  };

  fort.cluster.services = [
    {
      name = "backup-offsite";
      inherit port;
      visibility = "vpn";
      sso.mode = "none";
      maxBodySize = "100m";
    }
  ];
}
