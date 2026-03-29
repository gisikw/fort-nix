{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  subdomain = "vdirsyncer-auth";
  port = 8088;
  dataDir = "/var/lib/vdirsyncer";

  pythonEnv = pkgs.python3.withPackages (ps: [ ps.requests ]);

  oauthHelper = pkgs.writeScriptBin "vdirsyncer-oauth-helper" ''
    #!${pythonEnv}/bin/python3
    ${builtins.readFile ./oauth-helper.py}
  '';
in
{
  # Single user for both auth helper and sync timer eliminates the two-writer
  # permission problem that five previous fixes (group perms, chown, setgid,
  # default ACLs) couldn't solve — vdirsyncer's atomic writes create files
  # with mode 0600, zeroing the ACL mask regardless of directory defaults.
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0700 dev users"
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
    description = "vdirsyncer OAuth Helper";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "users";
      WorkingDirectory = dataDir;
      Restart = "always";
      RestartSec = 5;

      RuntimeDirectory = "vdirsyncer-auth";
      RuntimeDirectoryMode = "0700";

      # Hardening
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ dataDir ];
    };

    script = ''
      export OAUTH_CLIENT_ID=$(cat ${config.sops.secrets.oauth-client-id.path} | tr -d '\n')
      export OAUTH_CLIENT_SECRET=$(cat ${config.sops.secrets.oauth-client-secret.path} | tr -d '\n')
      export OAUTH_REDIRECT_URI="https://${subdomain}.${domain}/callback"
      export TOKEN_FILE="${dataDir}/token"
      export PORT="${toString port}"
      exec ${oauthHelper}/bin/vdirsyncer-oauth-helper
    '';
  };

  fort.cluster.services = [
    {
      name = "vdirsyncer-auth";
      inherit subdomain port;
      visibility = "public";
      sso = {
        mode = "gatekeeper";
        groups = [ "admin" ];
      };
    }
  ];
}
