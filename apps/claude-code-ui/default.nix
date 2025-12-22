{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  dataDir = "/var/lib/claude-code-ui";
  user = "claude-code-ui";
  group = "claude-code-ui";
  port = 3001;

  claude-code = import ../../pkgs/claude-code { inherit pkgs; };
  claude-code-ui = import ../../pkgs/claude-code-ui { inherit pkgs; };
in
{
  users.users.${user} = {
    isSystemUser = true;
    group = group;
    description = "Claude Code UI service user";
    home = dataDir;
  };

  users.groups.${group} = { };

  # Note: After first deploy, run `sudo -u claude-code-ui claude login` to authenticate
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 ${user} ${group}"
    "d ${dataDir}/.claude 0700 ${user} ${group}"
    "d ${dataDir}/projects 0755 ${user} ${group}"
  ];

  systemd.services.claude-code-ui = {
    description = "Claude Code UI";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      PORT = toString port;
      DATABASE_PATH = "${dataDir}/auth.db";
      HOME = dataDir;
      CLAUDE_CONFIG_DIR = "${dataDir}/.claude";
    };

    serviceConfig = {
      Type = "simple";
      User = user;
      Group = group;
      WorkingDirectory = dataDir;
      ExecStart = "${claude-code-ui}/bin/claude-code-ui";
      Restart = "on-failure";
      RestartSec = "10s";
      StateDirectory = "claude-code-ui";
    };

    path = [ claude-code pkgs.git ];
  };

  fortCluster.exposedServices = [
    {
      name = "claude-code-ui";
      subdomain = "claude";
      port = port;
      visibility = "vpn";
      sso = {
        mode = "gatekeeper";
        groups = [ "claude-users" ];
      };
    }
  ];
}
