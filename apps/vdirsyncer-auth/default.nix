{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  subdomain = "vdirsyncer-auth";
  port = 8088;
  dataDir = "/var/lib/vdirsyncer";
  homeDir = "/home/dev";
  share = "${homeDir}/.local/share/vdirsyncer";

  # calroom (Go, pkgs/calroom) replaced the single-account Python helper:
  # same URL and /callback (so the redirect URI registered on the OAuth
  # client still matches), any number of Google accounts, one token each
  # under tokens/. cal-sync (aspects/dev-sandbox) turns each token into a
  # read-only vdirsyncer pair. The original work-calendar token stays at
  # ${dataDir}/token.
  calroom = import ../../pkgs/calroom { inherit pkgs; };
in
{
  # Single user for both auth helper and sync timer eliminates the two-writer
  # permission problem that five previous fixes (group perms, chown, setgid,
  # default ACLs) couldn't solve — vdirsyncer's atomic writes create files
  # with mode 0600, zeroing the ACL mask regardless of directory defaults.
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0700 dev users"
    "d ${dataDir}/tokens 0700 dev users"
  ];

  sops.secrets.oauth-client-id = {
    sopsFile = ../../aspects/dev-sandbox/oauth-client-id.sops;
    format = "binary";
    owner = "dev";
    group = "users";
    mode = "0400";
  };

  sops.secrets.oauth-client-secret = {
    sopsFile = ../../aspects/dev-sandbox/oauth-client-secret.sops;
    format = "binary";
    owner = "dev";
    group = "users";
    mode = "0400";
  };

  systemd.services.vdirsyncer-auth = {
    description = "calroom: Google calendar accounts for vdirsyncer";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      OAUTH_CLIENT_ID_FILE = config.sops.secrets.oauth-client-id.path;
      OAUTH_CLIENT_SECRET_FILE = config.sops.secrets.oauth-client-secret.path;
      ORIGIN = "https://${subdomain}.${domain}";
      PORT = toString port;
      DATA_DIR = dataDir;
      LEGACY_EMAIL = "kgisi@alpinesg.com";
      GOOGLE_DATA_DIR = "${share}/google";
      STATUS_DIR = "${share}/status";
      LAST_SYNC_FILE = "${share}/.last_sync";
      AGENDA_FILE = "${share}/agenda.json";
      # "Sync now" runs the same script as the timer (flock-serialized).
      SYNC_CMD = "/run/current-system/sw/bin/cal-sync";
      VD_HOME = homeDir;
      VD_DATA = dataDir;
      LOCAL_CALENDARS = "Radicale: kevin (personal; the one Kes may write to);Radicale: family (shared)";
    };

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "users";
      WorkingDirectory = dataDir;
      ExecStart = "${calroom}/bin/calroom";
      Restart = "always";
      RestartSec = 5;

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      # cal-sync writes dev's vdirsyncer/khal state when "Sync now" runs it.
      ReadWritePaths = [
        dataDir
        "${homeDir}/.config/vdirsyncer"
        share
        "${homeDir}/.local/share/khal"
        "${homeDir}/.cache"
      ];
    };
  };

  fort.cluster.services = [
    {
      name = "vdirsyncer-auth";
      inherit subdomain port;
      visibility = "public";
      sso = { mode = "identity"; groups = [ "admin" ]; };
    }
  ];
}
