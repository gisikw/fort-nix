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
                      You are running as Tiamat's Claude Code routing arm. The caller may advertise request-scoped tools through the Tiamat MCP server. Do not claim to have executed those tools yourself. If a tool is needed, call the provided mcp__tiamat__* tool; Tiamat will defer that call and return it to the caller for execution.
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
