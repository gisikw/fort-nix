rec {
  hostName = "obrien";
  device = "FFD630C8-2D9B-5C34-BF1F-474943BDB2D9";

  roles = [ ];

  # apple-dist: the iOS ad-hoc distribution endpoint lives here so the CI
  # runner's publish step is a local copy (IPA + manifest plist land in
  # /var/lib/apple-dist/ipas, served at https://apple.<domain>).
  apps = [ "apple-dist" ];

  # ci-runner: Forgejo Actions runner (darwin branch — launchd daemon as
  # admin, labels macos:host + ios:host) for the hearth build pipeline.
  aspects = [
    "observable"
    "ci-runner"
  ];

  module =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      domain = config.fort.cluster.settings.domain;

      # HID-level simulator interaction (tap/swipe/type/describe-ui) for the
      # hearth-room iOS loop — see docs/obrien-muse-serve.md § Gestures.
      axe = import ../../../../pkgs/axe { inherit pkgs; };
      claude-code = import ../../../../pkgs/claude-code { inherit pkgs; };
      pi-coding-agent = (import ../../../../pkgs/pi-coding-agent { inherit pkgs; }).overrideAttrs (old: {
        # The npm package is architecture-independent and is proven on obrien;
        # the shared derivation's Linux-only metadata is overly restrictive.
        meta = old.meta // {
          platforms = lib.platforms.unix;
        };
      });

      # Keep the runtime source revision explicit: obrien's host generation,
      # rather than an imperative user profile, owns when golemd advances.
      golem =
        (builtins.getFlake "github:gisikw/golem/6767023fabf0f1cec7057ac3e84d1fac7254abe8")
        .packages.${pkgs.system}.full;
      golemStateDir = "/Users/admin/.local/state/golem";
      golemScratchDir = "/Users/admin/Projects/golem-scratch";
      golemdConfig = pkgs.writeText "golemd-obrien.toml" ''
        name = "obrien"
        clone_enabled = true
        api_bearer_tokens = []

        [providers.tiamat-anthropic-claude-code-personal]
        kind = "tiamat"

        [providers.tiamat-responses-codex-personal]
        kind = "tiamat"

        [providers.tiamat-openai-llama-frankenstein]
        kind = "tiamat"

        [harnesses.pi]
        models = [
          "tiamat-anthropic-claude-code-personal/claude-fable-5",
          "tiamat-anthropic-claude-code-personal/claude-haiku-4-5-20251001",
          "tiamat-anthropic-claude-code-personal/claude-opus-4-6",
          "tiamat-anthropic-claude-code-personal/claude-opus-4-7",
          "tiamat-anthropic-claude-code-personal/claude-opus-4-8",
          "tiamat-anthropic-claude-code-personal/claude-opus-5",
          "tiamat-anthropic-claude-code-personal/claude-sonnet-4-6",
          "tiamat-anthropic-claude-code-personal/claude-sonnet-5",
          "tiamat-responses-codex-personal/codex-auto-review",
          "tiamat-responses-codex-personal/gpt-5.4",
          "tiamat-responses-codex-personal/gpt-5.4-mini",
          "tiamat-responses-codex-personal/gpt-5.5",
          "tiamat-responses-codex-personal/gpt-5.6-luna",
          "tiamat-responses-codex-personal/gpt-5.6-sol",
          "tiamat-responses-codex-personal/gpt-5.6-terra",
          "tiamat-responses-codex-personal/gpt-reserve",
          "tiamat-openai-llama-frankenstein/Qwen3.8-27B-UD-Q4_K_XL",
        ]

        [harnesses.fake]
        models = []

        [projects.scratch]
        path = "${golemScratchDir}"
        description = "OBrien scratch repository"

        [attach_ssh]
        port = 0
      '';
      golemdPath = lib.makeBinPath [
        golem
        pi-coding-agent
        pkgs.git
        pkgs.tmux
        pkgs.bashInteractive
      ];

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
        touch /var/log/muse-serve.log /var/log/golemd.log
        chown admin:staff /var/log/muse-serve.log /var/log/golemd.log
        chmod 0644 /var/log/muse-serve.log /var/log/golemd.log

        mkdir -p ${golemStateDir} ${golemScratchDir}
        chown admin:staff ${golemStateDir} ${golemScratchDir}
        chmod 0700 ${golemStateDir}
        if ! ${pkgs.git}/bin/git -C ${golemScratchDir} rev-parse --git-dir >/dev/null 2>&1; then
          /usr/bin/su admin -c '${pkgs.git}/bin/git -C ${golemScratchDir} init'
        fi
        if ! ${pkgs.git}/bin/git -C ${golemScratchDir} rev-parse --verify HEAD >/dev/null 2>&1; then
          /usr/bin/su admin -c "${pkgs.git}/bin/git -C ${golemScratchDir} -c user.name='Golem Bootstrap' -c user.email='golem@obrien' commit --allow-empty -m 'Initialize Golem scratch project'"
        fi
      '';

      # Shared Router credential, encrypted in fort-nix and materialized only
      # on obrien. The old ~/.config token is not part of the service contract.
      config.sops.secrets.tiamat-router-token = {
        sopsFile = ./golemd-tiamat-router-token.sops;
        format = "binary";
        owner = "admin";
        group = "staff";
        mode = "0400";
      };

      config.launchd.daemons.golemd = {
        serviceConfig = {
          Label = "network.gisi.golemd";
          ProgramArguments = [
            "${golem}/bin/golemd"
            "--config"
            "${golemdConfig}"
            "--state"
            golemStateDir
            "--listen"
            "127.0.0.1:9920"
            "--linger"
            "1h"
          ];
          UserName = "admin";
          GroupName = "staff";
          WorkingDirectory = "/Users/admin";
          RunAtLoad = true;
          KeepAlive = true;
          ThrottleInterval = 5;
          StandardOutPath = "/var/log/golemd.log";
          StandardErrorPath = "/var/log/golemd.log";
          EnvironmentVariables = {
            HOME = "/Users/admin";
            PATH = "${golemdPath}:/usr/bin:/bin:/usr/sbin:/sbin";
            GOLEM_INTERACTIVE_SHELL = "${pkgs.bashInteractive}/bin/bash";
            GOLEM_TIAMAT_URL = "https://router.gisi.network";
            GOLEM_TIAMAT_TOKEN_FILE = config.sops.secrets.tiamat-router-token.path;
          };
        };
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

      # Git credential helper for Forgejo access
      config.environment.etc."fort-git-credential-helper".source =
        pkgs.writeShellScript "fort-git-credential-helper" ''
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
        request = {
          access = "rw";
        };
        handler = gitTokenHandler;
      };

      config.fort.host = { inherit roles apps aspects; };
    };
}
