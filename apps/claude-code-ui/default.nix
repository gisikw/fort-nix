{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  dataDir = "/var/lib/claude-code-ui";
  user = "claude-code-ui";
  group = "claude-code-ui";
  port = 3001;

  claude-code-ui = import ../../pkgs/claude-code-ui { inherit pkgs; };

  # Wrapper script that sets up PATH and runs claude-code-ui
  startScript = pkgs.writeShellScript "start-claude-code-ui" ''
    export PATH=${dataDir}/.npm-global/bin:$PATH
    exec ${claude-code-ui}/bin/claude-code-ui "$@"
  '';

  # Script to ensure claude-code is installed via npm
  ensureClaudeCode = pkgs.writeShellScript "ensure-claude-code" ''
    export HOME=${dataDir}
    export NPM_CONFIG_PREFIX=${dataDir}/.npm-global
    export PATH=${dataDir}/.npm-global/bin:$PATH

    mkdir -p ${dataDir}/.npm-global

    if ! command -v claude &>/dev/null; then
      echo "Installing @anthropic-ai/claude-code via npm..."
      ${pkgs.nodejs}/bin/npm install -g @anthropic-ai/claude-code
    fi
  '';
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
    "d ${dataDir}/.npm-global 0755 ${user} ${group}"
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
      VITE_IS_PLATFORM = "true";
      NPM_CONFIG_PREFIX = "${dataDir}/.npm-global";
    };

    serviceConfig = {
      Type = "simple";
      User = user;
      Group = group;
      WorkingDirectory = dataDir;
      ExecStartPre = "${ensureClaudeCode}";
      ExecStart = startScript;
      Restart = "on-failure";
      RestartSec = "10s";
      StateDirectory = "claude-code-ui";
    };

    path = [ pkgs.nodejs pkgs.git ];
  };

  fortCluster.exposedServices = [
    {
      name = "claude-code-ui";
      subdomain = "claude";
      port = port;
      visibility = "vpn";
      sso = {
        mode = "gatekeeper";
        groups = [ ];  # Temporarily disabled for platform mode testing
      };
    }
  ];
}
