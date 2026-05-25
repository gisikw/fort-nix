{ rootManifest, hostManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  repoUrl = "rest:https://backup.${domain}/";
  passwordPath = config.sops.secrets.restic-password.path;
  hostname = hostManifest.hostName;
in
{
  environment.systemPackages = [ pkgs.restic ];

  sops.secrets.restic-password = {
    sopsFile = ./restic-password.sops;
    format = "binary";
    mode = "0400";
  };

  services.restic.backups.system = {
    repository = repoUrl;
    passwordFile = passwordPath;
    paths = [ "/var/lib" ];
    exclude = [
      "/var/lib/docker"
      "/var/lib/containers"
      "/var/lib/systemd"
      "/var/lib/nixos"
      "*.log"
      "*.log.*"
      "/var/lib/restic-repos"
    ];
    extraBackupArgs = [
      "--tag" hostname
      "--exclude-caches"
    ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };

  # PostgreSQL backup if enabled on this host
  services.restic.backups.postgres = lib.mkIf config.services.postgresql.enable {
    repository = repoUrl;
    passwordFile = passwordPath;
    backupPrepareCommand = ''
      ${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/pg_dumpall \
        > /tmp/restic-postgres-backup.sql
    '';
    paths = [ "/tmp/restic-postgres-backup.sql" ];
    backupCleanupCommand = "rm -f /tmp/restic-postgres-backup.sql";
    extraBackupArgs = [
      "--tag" "${hostname}-postgres"
    ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };

  # Retention policy: prune old snapshots after backup
  services.restic.backups.system.pruneOpts = [
    "--keep-daily 7"
    "--keep-weekly 4"
    "--keep-monthly 6"
  ];
}
