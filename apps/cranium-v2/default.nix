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
    after = [ "network.target" "postgresql.service" ];
    wants = [ "postgresql.service" ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "users";
      WorkingDirectory = projectDir;
      EnvironmentFile = "${projectDir}/.env";
      ExecStart = "${pkgs.elixir}/bin/mix run --no-halt";
      Restart = "on-failure";
      RestartSec = 5;

      Environment = [
        "HOME=/home/dev"
        "MIX_ENV=dev"
        "PATH=${pkgs.lib.makeBinPath (with pkgs; [ elixir erlang git coreutils bash ])}:/run/current-system/sw/bin"
      ];
    };
  };

  fort.cluster.services = [
    {
      name = "craniumv2";
      inherit port;
      visibility = "public";
      sso = {
        mode = "token";
        vpnBypass = true;
      };
    }
  ];
}
