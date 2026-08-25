rec {
  hostName = "azula";
  device = "166401ec-95f9-6543-854d-a8595f97cd63";

  roles = [ ];

  apps = [
    # {
    #   name = "llama-server";
    #   accelerator = "cpu";
    #   subdomain = "llama2";
    #   serviceName = "llama2";
    #   contextSize = 131072;
    #   enableMtp = true;
    #   model = {
    #     repo = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF";
    #     file = "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf";
    #     sha256 = "55983c5a75a1ab969824077b3bb3de4146e82a9234072b48ad4e8f92ad3fe9f1";
    #   };
    # }
  ];

  aspects = [
    "observable"
    "agent-debug"
    "familiar-test"
  ];

  module =
    { config, pkgs, ... }:
    let
      golem = import ../../../../pkgs/golem { inherit pkgs; };
      golemdConfig = pkgs.writeText "golemd-azula.toml" ''
        name = "azula"
        clone_enabled = false
        api_bearer_tokens = []

        [providers.llama]
        base_url = "https://llama.gisi.network/v1"
        api_key_env = ""

        [harnesses.pi]
        models = ["llama/Qwen3.8-27B-UD-Q4_K_XL"]

        [harnesses.fake]
        models = []

        [projects.scratch]
        path = "/var/lib/golem/projects/scratch"
        description = "Azula scratch repository"

        [attach_ssh]
        port = 0
      '';
    in
    {
      config.fort.host = { inherit roles apps aspects; };

      # Manual Familiar rewrite test deployment. Keep the account declarative so
      # GitOps activation does not remove the long-running Presence/supervisor
      # owner created during pre-cutover testing.
      config.users.users.familiar = {
        isNormalUser = true;
        home = "/home/familiar";
        createHome = true;
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = [ config.fort.cluster.settings.principals.admin.publicKey ];
      };

      # Shared credential used by the Familiar rewrite stack to authenticate to
      # tiamat-router without placing the token in the Nix store.
      config.sops.secrets.tiamat-router-token = {
        sopsFile = ../../../../aspects/dev-sandbox/tiamat-router-token.sops;
        format = "binary";
        path = "/run/secrets/tiamat-router-token";
        owner = "familiar";
        group = "users";
        mode = "0400";
      };

      config.users.groups.golem = { };
      config.users.users.golem = {
        isSystemUser = true;
        group = "golem";
        home = "/var/lib/golem";
      };

      config.systemd.services.golemd = {
        description = "Golem delegated-agent daemon";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.git ];
        preStart = ''
          set -euo pipefail
          scratch=/var/lib/golem/projects/scratch
          marker="$scratch/.golem-bootstrap-v1"
          mkdir -p "$scratch"
          if [ ! -e "$marker" ]; then
            if ! git -C "$scratch" rev-parse --git-dir >/dev/null 2>&1; then
              git -C "$scratch" init
            fi
            if ! git -C "$scratch" rev-parse --verify HEAD >/dev/null 2>&1; then
              git -C "$scratch" \
                -c user.name='Golem Bootstrap' \
                -c user.email='golem@azula' \
                commit --allow-empty -m 'Initialize Golem scratch project'
            fi
            touch "$marker"
          fi
        '';
        serviceConfig = {
          User = "golem";
          Group = "golem";
          StateDirectory = "golem";
          StateDirectoryMode = "0750";
          ExecStart = "${golem}/bin/golemd --config ${golemdConfig} --state /var/lib/golem --listen 127.0.0.1:9920";
          Restart = "on-failure";
        };
      };

      config.environment.variables.GOLEM_ENDPOINT = "http://127.0.0.1:9920";

      # Office captive-portal survival kit. Azula may need to register on
      # unfamiliar networks before it can fetch anything else, so keep both a
      # graphical browser path and text-mode/debug tools available locally.
      config.services.xserver.enable = true;
      config.services.xserver.displayManager.lightdm.enable = true;
      config.services.xserver.desktopManager.xfce.enable = true;

      config.environment.systemPackages = with pkgs; [
        golem
        firefox
        w3m
        lynx
        curl
        wget
        dnsutils
        openssl
        xterm
      ];
    };
}
