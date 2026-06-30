rec {
  hostName = "lordhenry";
  device = "17f17980-5d30-11f0-9a98-fe3a96b43f00";

  roles = [ ];

  apps = [
    "comfyui"
    "ollama"
    "open-webui"
    "qmd"
    "sillytavern"
    "stt"
    "tts"
    "whisper"
  ];

  overlays = {
    tiamat = {
      package = "infra/tiamat";
      config = {
        port = "8900";
        user = "tiamat";
        group = "tiamat";
        home = "/var/lib/tiamat";
      };
      expose = {
        port = 8900;
        visibility = "public";
        sso = {
          mode = "identity";
          groups = [
            "admin"
            "infra"
          ];
        };
      };
    };
  };

  aspects = [
    "mesh"
    "observable"
    "gitops"
  ];

  module =
    { config, pkgs, ... }:
    let
      tiamatProfilesYaml = pkgs.writeText "tiamat-profiles.yaml" ''
        prompt_root: /var/lib/tiamat/prompts
        profiles:
          exo:
            default_arm: claude_code
            arms:
              claude_code:
                backend: claude_code
                provider: anthropic
                model: claude_code
                supports_vision: true
                system_prompt:
                  - id: claude-code-v0-tool-defer-steering
                    file: claude-code-v0-tool-defer.md
                  - id: exo-opus-behavioral
                    file: exo-opus.md

          exo-claude-code:
            default_arm: claude_code
            arms:
              claude_code:
                backend: claude_code
                provider: anthropic
                model: claude_code
                supports_vision: true
                system_prompt:
                  - id: claude-code-v0-tool-defer-steering
                    file: claude-code-v0-tool-defer.md
                  - id: exo-opus-behavioral
                    file: exo-opus.md

          exo-opus-api:
            default_arm: opus-api
            arms:
              opus-api:
                backend: anthropic
                provider: anthropic
                model: claude-opus-4-6
                supports_vision: true
                max_tokens: 8192
                system_prompt:
                  - id: exo-opus-behavioral
                    file: exo-opus.md
                backend_config:
                  api_key_file: /run/secrets/tiamat-anthropic-api-key

          exo-gpt:
            default_arm: gpt-oauth
            arms:
              gpt-oauth:
                backend: openai_responses
                provider: openai
                model: gpt-5.5
                supports_vision: true
                max_tokens: 8192
                system_prompt:
                  - id: exo-gpt-behavioral
                    file: exo-gpt.md
                backend_config:
                  endpoint: https://chatgpt.com/backend-api/codex
                  auth: oauth
                  oauth_token_file: /var/lib/tiamat/openai_oauth.json

          exo-qwen-local:
            default_arm: llama-local
            arms:
              llama-local:
                backend: openai_compat
                provider: llama.cpp
                model: qwen3.6-27b
                supports_vision: true
                max_tokens: 8192
                thinking: false
                backend_config:
                  endpoint: https://llama.gisi.network/v1
                  thinking_mode: prefill

          qwen-local:
            default_arm: llama-local
            arms:
              llama-local:
                backend: openai_compat
                provider: llama.cpp
                model: qwen3.6-27b
                supports_vision: true
                max_tokens: 8192
                thinking: false
                backend_config:
                  endpoint: https://llama.gisi.network/v1
                  thinking_mode: prefill

          exo-glm:
            default_arm: opencode
            arms:
              opencode:
                backend: openai_compat
                provider: opencode
                model: glm-5.2
                max_tokens: 8192
                backend_config:
                  endpoint: https://opencode.ai/zen/go/v1
                  api_key_file: /run/secrets/tiamat-opencode-api-key
      '';
      tiamatAnthropicSecretDropin = pkgs.writeText "tiamat-anthropic-secret-file.conf" ''
        [Service]
        Environment=TIAMAT_ANTHROPIC_API_KEY_FILE=${config.sops.secrets.tiamat-anthropic-api-key.path}
        UnsetEnvironment=ANTHROPIC_API_KEY
      '';
    in
    {
      # Disable Compute Wave Store and Resume — MES firmware bug on gfx1151
      # causes GPU hangs under ROCm workloads (ROCm #5590)
      config.boot.kernelParams = [ "amdgpu.cwsr_enable=0" ];

      config.environment.systemPackages = [
        (import ../../../../pkgs/claude-code { inherit pkgs; })
        pkgs.ffmpeg
        pkgs.neovim
        pkgs.tailscale
        pkgs.tmux
        pkgs.rsync
      ];

      config.users.groups.tiamat = { };
      config.users.users.tiamat = {
        isSystemUser = true;
        group = "tiamat";
        description = "Tiamat service user";
        home = "/var/lib/tiamat";
        createHome = true;
        shell = pkgs.bashInteractive;
      };

      config.systemd.tmpfiles.rules = [
        "d /var/lib/tiamat 0750 tiamat tiamat -"
        "d /var/lib/tiamat/prompts 0700 tiamat tiamat -"
        "d /var/lib/tiamat/claude 0700 tiamat tiamat -"
        "d /var/lib/tiamat/.cache 0700 tiamat tiamat -"
        "d /var/lib/tiamat/.local 0700 tiamat tiamat -"
        "d /var/lib/tiamat/.local/state 0700 tiamat tiamat -"
        "d /var/lib/tiamat/.local/share 0700 tiamat tiamat -"
        # Repair ownership after migrating away from DynamicUser-created
        # /var/lib/private/tiamat state. Preserve existing file modes.
        "Z /var/lib/tiamat - tiamat tiamat -"
      ];

      config.sops.secrets.tiamat-exo-opus-prompt = {
        sopsFile = ./exo-opus-prompt.sops;
        format = "binary";
        path = "/var/lib/tiamat/prompts/exo-opus.md";
        owner = "tiamat";
        group = "tiamat";
        mode = "0400";
      };

      config.sops.secrets.tiamat-exo-gpt-prompt = {
        sopsFile = ./exo-gpt-prompt.sops;
        format = "binary";
        path = "/var/lib/tiamat/prompts/exo-gpt.md";
        owner = "tiamat";
        group = "tiamat";
        mode = "0400";
      };

      config.sops.secrets.tiamat-claude-code-tool-defer-prompt = {
        sopsFile = ./claude-code-tool-defer-prompt.sops;
        format = "binary";
        path = "/var/lib/tiamat/prompts/claude-code-v0-tool-defer.md";
        owner = "tiamat";
        group = "tiamat";
        mode = "0400";
      };

      config.sops.secrets.tiamat-anthropic-api-key = {
        sopsFile = ./tiamat-anthropic-api-key.sops;
        format = "binary";
        owner = "tiamat";
        group = "tiamat";
        mode = "0400";
      };

      config.sops.secrets.tiamat-opencode-api-key = {
        sopsFile = ./tiamat-opencode-api-key.sops;
        format = "binary";
        owner = "tiamat";
        group = "tiamat";
        mode = "0400";
      };

      # Tiamat should read provider API credentials from scoped secret files.
      # Do not expose ANTHROPIC_API_KEY globally: Claude Code subprocesses must
      # continue using their OAuth state rather than accidentally switching to
      # API-key auth inherited from the parent process.
      config.system.activationScripts.tiamatAnthropicSecretDropin.text = ''
        install -D -m 0644 ${tiamatAnthropicSecretDropin} /etc/systemd/system/overlay-tiamat-tiamat.service.d/10-anthropic-secret-file.conf
      '';

      config.systemd.services.tiamat-profiles-provision = {
        description = "Provision Tiamat profile configuration";
        wantedBy = [ "multi-user.target" ];
        before = [ "overlay-tiamat-tiamat.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          ${pkgs.coreutils}/bin/install -D -o tiamat -g tiamat -m 0440 ${tiamatProfilesYaml} /var/lib/tiamat/profiles.yaml
        '';
      };

      config.environment.interactiveShellInit = ''
        if [ "''${USER:-}" = "tiamat" ]; then
          export HOME=/var/lib/tiamat
          export CLAUDE_CONFIG_DIR=/var/lib/tiamat/claude
          export XDG_CACHE_HOME=/var/lib/tiamat/.cache
          export XDG_STATE_HOME=/var/lib/tiamat/.local/state
          export XDG_DATA_HOME=/var/lib/tiamat/.local/share
        fi
      '';

      config.fort.host = { inherit roles apps aspects; };
    };
}
