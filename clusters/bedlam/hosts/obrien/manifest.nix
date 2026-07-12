rec {
  hostName = "obrien";
  device = "FFD630C8-2D9B-5C34-BF1F-474943BDB2D9";

  roles = [ ];

  apps = [ ];

  aspects = [ "observable" ];

  module =
    { config, pkgs, ... }:
    {
      config.environment.systemPackages = [
        pkgs.xcodes
      ];

      # muse serve: HTTP exec transport so cranium (ratched) can run tool
      # calls on this host (Xcode/simulator work). The binary is installed
      # manually at /usr/local/bin/muse — see docs/obrien-muse-serve.md.
      # Cranium's `hearth` profile is pinned to
      # http://obrien.fort.gisi.network:4600 with this token.
      config.sops.secrets.muse-serve-token = {
        sopsFile = ./muse-serve-token.sops;
        format = "binary";
        mode = "0400";
        owner = "admin";
      };

      config.launchd.daemons.muse-serve = {
        serviceConfig = {
          Label = "network.gisi.muse.serve";
          ProgramArguments = [
            "/usr/local/bin/muse"
            "serve"
            "--addr"
            "0.0.0.0:4600"
            "--token-file"
            config.sops.secrets.muse-serve-token.path
          ];
          # System-domain daemon (not the gui LaunchAgent from muse's
          # packaging template): it must be up without a GUI login, and
          # ssh-driven xcodebuild already works in non-GUI contexts.
          UserName = "admin";
          GroupName = "staff";
          WorkingDirectory = "/Users/admin";
          RunAtLoad = true;
          KeepAlive = true;
          # Token file appears only after sops-install-secrets runs at
          # activation; fail-closed restarts every 5s until then.
          ThrottleInterval = 5;
          StandardOutPath = "/var/log/muse-serve.log";
          StandardErrorPath = "/var/log/muse-serve.log";
          EnvironmentVariables = {
            HOME = "/Users/admin";
            PATH = "/usr/local/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
          };
        };
      };

      config.fort.host = { inherit roles apps aspects; };
    };
}
