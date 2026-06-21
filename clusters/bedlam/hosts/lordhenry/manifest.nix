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
        sso = { mode = "identity"; groups = [ "admin" "infra" ]; };
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
                system_prompt:
                  - id: claude-code-v0-tool-defer-steering
                    text: |
                      When a requested action requires tools unavailable inside Claude Code, do not pretend to perform the action.
                      State the required tool/action clearly so Tiamat/Cranium can route or fulfill it outside Claude Code.
                  - id: exo-opus-behavioral
                    file: exo-opus.md
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
        "C+ /var/lib/tiamat/profiles.yaml 0440 tiamat tiamat - ${tiamatProfilesYaml}"
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
