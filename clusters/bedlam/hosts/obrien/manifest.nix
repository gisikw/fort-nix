rec {
  hostName = "obrien";
  device = "FFD630C8-2D9B-5C34-BF1F-474943BDB2D9";

  roles = [ ];

  apps = [ ];

  aspects = [ "observable" ];

  module =
    { config, pkgs, lib, ... }:
    let
      domain = config.fort.cluster.settings.domain;

      # HID-level simulator interaction (tap/swipe/type/describe-ui) for the
      # hearth-room iOS loop — see docs/obrien-muse-serve.md § Gestures.
      axe = import ../../../../pkgs/axe { inherit pkgs; };
      claude-code = import ../../../../pkgs/claude-code { inherit pkgs; };

      # Git token handler: extracts token from JSON response and stores it
      gitTokenDir = "/var/lib/fort-git";
      gitTokenHandler = pkgs.writeShellScript "git-token-handler" ''
        ${pkgs.coreutils}/bin/mkdir -p ${gitTokenDir}
        ${pkgs.jq}/bin/jq -r '.token' > ${gitTokenDir}/dev-token
        ${pkgs.coreutils}/bin/chmod 644 ${gitTokenDir}/dev-token
      '';
    in
    {
      config.environment.systemPackages = [
        pkgs.xcodes
        pkgs.tmux
        pkgs.git
        pkgs.jq
        axe
        claude-code
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

      # launchd opens Standard{Out,Error}Path as the daemon's UserName, and
      # /var/log is not admin-writable — without this the spawn itself fails
      # with EX_CONFIG (78) and no log is ever written. Pre-create the file
      # root-side so the admin-uid open succeeds and `fort obrien journal`
      # keeps its /var/log/<name>.log convention.
      config.system.activationScripts.postActivation.text = ''
        touch /var/log/muse-serve.log
        chown admin:staff /var/log/muse-serve.log
        chmod 0644 /var/log/muse-serve.log
      '';

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

      # Git credential helper for Forgejo access
      config.environment.etc."fort-git-credential-helper".source = pkgs.writeShellScript "fort-git-credential-helper" ''
        case "$1" in
          get)
            if [ -s "${gitTokenDir}/dev-token" ]; then
              TOKEN=$(cat "${gitTokenDir}/dev-token")
            else
              exit 0
            fi
            echo "username=forge-admin"
            echo "password=$TOKEN"
            ;;
        esac
      '';

      # Configure git to use the credential helper for the forge
      config.environment.etc."gitconfig".text = ''
        [credential "https://git.${domain}"]
          helper = /etc/fort-git-credential-helper
        [init]
          defaultBranch = main
      '';

      # Request RW git token from forge via control plane
      config.fort.host.needs.git-token.dev = {
        from = "drhorrible";
        request = { access = "rw"; };
        handler = gitTokenHandler;
      };

      config.fort.host = { inherit roles apps aspects; };
    };
}
