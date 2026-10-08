# Optional manifest params (defaults keep the original whole-/var/lib sweep):
#   paths           what the `system` backup covers (default [ "/var/lib" ])
#   extraExcludes   appended to the default exclude list
#   sqliteSnapshots live SQLite DBs to copy with `.backup` (consistent online
#                   snapshot) into ${stagingDir} before each `system` run; the
#                   staging dir is added to paths and cleared afterwards.
#                   On disk, not /tmp: azula's /tmp is tmpfs.
{ rootManifest, hostManifest, deviceProfileManifest
, paths ? [ "/var/lib" ]
, extraExcludes ? [ ]
, sqliteSnapshots ? [ ]
, ... }:
{ config, lib, pkgs, ... }:
if (deviceProfileManifest.platform or "nixos") != "nixos" then
  throw "fort-nix: aspect 'backup-client' is Linux-only (services.restic systemd timers); remove it from this darwin host's manifest"
else
let
  domain = rootManifest.fortConfig.settings.domain;
  repoUrl = "rest:https://backup.${domain}/";
  passwordPath = config.sops.secrets.restic-password.path;
  hostname = hostManifest.hostName;
  stagingDir = "/var/lib/restic-staging";
  # /var/lib/kestrel/state/agents/agents.sqlite3 -> var_lib_kestrel_state_agents_agents.sqlite3
  snapName = db: lib.replaceStrings [ "/" ] [ "_" ] (lib.removePrefix "/" db);
  hasSnapshots = sqliteSnapshots != [ ];
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
    paths = paths ++ lib.optional hasSnapshots stagingDir;
    backupPrepareCommand = lib.mkIf hasSnapshots ''
      set -eu
      rm -rf ${stagingDir}
      mkdir -p -m 0700 ${stagingDir}
      ${lib.concatMapStringsSep "\n" (db: ''
        if [ -f ${lib.escapeShellArg db} ]; then
          ${pkgs.sqlite}/bin/sqlite3 ${lib.escapeShellArg db} ".timeout 10000" ".backup '${stagingDir}/${snapName db}'"
        else
          echo "backup-client: sqlite snapshot source missing: ${db}" >&2
        fi
      '') sqliteSnapshots}
    '';
    backupCleanupCommand = lib.mkIf hasSnapshots "rm -rf ${stagingDir}";
    exclude = extraExcludes ++ [
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

  # Questbook SQLite backup, gated to hosts running the questbook overlay.
  # The `system` backup above already sweeps /var/lib/questbook, but a raw
  # filesystem copy of a live SQLite DB can be torn (main file vs -wal captured
  # at different instants). Take a consistent online-backup snapshot first so
  # the questbook corpus (1400+ imported tickets) has a restorable copy — this
  # is the cutover's insurance, mirroring the postgres pattern below.
  services.restic.backups.questbook = lib.mkIf ((hostManifest.overlays or { }) ? questbook) {
    repository = repoUrl;
    passwordFile = passwordPath;
    backupPrepareCommand = ''
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/questbook/questbook.sqlite \
        ".backup '/tmp/restic-questbook-backup.sqlite'"
    '';
    paths = [ "/tmp/restic-questbook-backup.sqlite" ];
    backupCleanupCommand = "rm -f /tmp/restic-questbook-backup.sqlite";
    extraBackupArgs = [
      "--tag" "${hostname}-questbook"
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

}
