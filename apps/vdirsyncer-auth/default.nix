{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  subdomain = "vdirsyncer-auth";
  port = 8088;
  dataDir = "/var/lib/vdirsyncer";
  user = "vdirsyncer";
  group = "vdirsyncer";

  pythonEnv = pkgs.python3.withPackages (ps: [ ps.requests ]);

  oauthHelper = pkgs.writeScriptBin "vdirsyncer-oauth-helper" ''
    #!${pythonEnv}/bin/python3
    ${builtins.readFile ./oauth-helper.py}
  '';
in
{
  users.users.${user} = {
    isSystemUser = true;
    group = group;
    description = "vdirsyncer OAuth service";
    home = dataDir;
  };

  users.groups.${group} = { };

  # Allow dev user to read the token file
  users.users.dev.extraGroups = [ group ];

  # Mode 0770: group write needed for token refresh (vdirsyncer writes temp files)
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0770 ${user} ${group}"
  ];

  age.secrets.oauth-client-id = {
    file = ../../aspects/dev-sandbox/oauth-client-id.age;
    owner = user;
    group = group;
    mode = "0400";
  };

  age.secrets.oauth-client-secret = {
    file = ../../aspects/dev-sandbox/oauth-client-secret.age;
    owner = user;
    group = group;
    mode = "0400";
  };

  systemd.services.vdirsyncer-auth = {
    description = "vdirsyncer OAuth Helper";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = user;
      Group = group;
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
      export OAUTH_CLIENT_ID=$(cat ${config.age.secrets.oauth-client-id.path} | tr -d '\n')
      export OAUTH_CLIENT_SECRET=$(cat ${config.age.secrets.oauth-client-secret.path} | tr -d '\n')
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
      };
    }
  ];
}
