{ ... }:
{ pkgs, ... }:

let
  port = 4001;
  projectDir = "/home/dev/Projects/xo";
in
{
  systemd.services.xo = {
    description = "XO - Command center dashboard";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "users";
      WorkingDirectory = projectDir;
      ExecStart = "${pkgs.elixir}/bin/mix phx.server";
      Restart = "on-failure";
      RestartSec = 5;

      Environment = [
        "HOME=/home/dev"
        "MIX_ENV=dev"
        "PORT=${toString port}"
        "PATH=${pkgs.lib.makeBinPath (with pkgs; [ elixir erlang git coreutils bash esbuild tailwindcss_4 ])}:/home/dev/.local/bin:/run/current-system/sw/bin"
        "FORT_SSH_KEY=/var/lib/fort/dev-sandbox/agent-key"
        "FORT_ORIGIN=dev-sandbox"
      ];
    };
  };

  fort.cluster.services = [
    {
      name = "xo";
      inherit port;
      visibility = "public";
      sso = {
        mode = "oidc";
        vpnBypass = true;
      };
    }
  ];
}
