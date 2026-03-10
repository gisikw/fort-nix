{ ... }:
{ pkgs, ... }:

let
  port = 4000;
  projectDir = "/home/dev/Projects/cranium-v2";
in
{
  systemd.services.cranium-v2 = {
    description = "Cranium v2 - LLM inference pipeline HTTP API";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "postgresql.service" ];
    wants = [ "network-online.target" "postgresql.service" ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "users";
      WorkingDirectory = projectDir;
      EnvironmentFile = [
        "${projectDir}/.env"
        "/var/lib/fort/dev-sandbox/env"
      ];
      Restart = "on-failure";
      RestartSec = 5;
    };
    environment = {
      HOME = "/home/dev";
      MIX_ENV = "dev";
      FORT_SSH_KEY = "/var/lib/fort/dev-sandbox/agent-key";
      FORT_ORIGIN = "dev-sandbox";
    };
    path = with pkgs; [ elixir erlang git coreutils bash ffmpeg ];
    script = ''
      . /etc/set-environment
      export PATH="/home/dev/.local/bin:$PATH"
      exec mix run --no-halt
    '';
  };

  fort.cluster.services = [
    {
      name = "cranium";
      inherit port;
      visibility = "public";
      sso = {
        mode = "token";
        vpnBypass = true;
      };
    }
  ];
}
