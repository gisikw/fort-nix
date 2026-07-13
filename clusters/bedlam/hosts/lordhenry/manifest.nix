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
    grotto = {
      package = "infra/grotto";
      config = {
        port = "9410";
        dataDir = "/home/dev/.local/share/grotto";
        user = "grotto";
        group = "grotto";
      };
      # VPN-only (no visibility key): grotto is unauthenticated blob
      # storage; consumers are internal services (cranium, tiamat). No sso
      # so service-to-service calls don't hit oauth2-proxy.
      expose = {
        subdomain = "grotto";
        port = 9410;
      };
    };
    kobold = {
      package = "infra/kobold";
      # Pull-based worker only (role=worker): claims shell nodes tagged
      # "lordhenry" from the coordinator on ratched. Runs as the tiamat
      # service user so claimed work (nightly labeler) can read/write
      # tiamat's data dir. No expose — the worker is outbound-only.
      config = {
        role = "worker";
        workerConfigFile = "/etc/kobold/worker.json";
        workerUser = "tiamat";
        workerGroup = "tiamat";
      };
      secrets = {
        # KOBOLD_WORKER_TOKEN=… env file; must match the coordinator's
        # token on ratched (/home/dev/.config/kobold/worker-token).
        workerTokenEnvFile = ./kobold-worker-token-env.sops;
      };
    };
    tiamat = {
      package = "infra/tiamat";
      config = {
        port = "8900";
        user = "tiamat";
        group = "tiamat";
        home = "/var/lib/tiamat";
        grottoUrl = "https://grotto.gisi.network";
      };
      expose = {
        port = 8900;
        visibility = "public";
        maxBodySize = "50m";
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
                model: claude-opus-4-6
                supports_vision: true
                backend_config:
                  strip_continuation_artifacts: true
                system_prompt:
                  - id: exo-opus-behavioral
                    file: exo-opus.md

          exo-claude-code:
            default_arm: claude_code
            arms:
              claude_code:
                backend: claude_code
                provider: anthropic
                model: claude-opus-4-6
                supports_vision: true
                system_prompt:
                  - id: exo-opus-behavioral
                    file: exo-opus.md

          exo-fable:
            default_arm: claude_code_fable
            arms:
              claude_code_fable:
                backend: claude_code
                provider: anthropic
                model: claude-fable-5
                supports_vision: true
                system_prompt:
                  - id: fable-arm-steering
                    text: |
                      You are running as Tiamat's Claude Code Fable routing arm. The selected Claude Code model is Claude Fable 5. Your training cutoff is January 2026.

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

          exo-gpt-sol:
            default_arm: gpt-oauth
            arms:
              gpt-oauth:
                backend: openai_responses
                provider: openai
                model: gpt-5.6-sol
                supports_vision: true
                max_tokens: 8192
                system_prompt:
                  - id: exo-gpt-behavioral
                    file: exo-gpt.md
                backend_config:
                  endpoint: https://chatgpt.com/backend-api/codex
                  auth: oauth
                  oauth_token_file: /var/lib/tiamat/openai_oauth.json

          anthropic-opus-4-6:
            default_arm: opus-api
            arms:
              opus-api:
                backend: anthropic
                provider: anthropic
                model: claude-opus-4-6
                supports_vision: true
                max_tokens: 8192
                backend_config:
                  api_key_file: /run/secrets/tiamat-anthropic-api-key

          anthropic-sonnet-5:
            default_arm: sonnet-api
            arms:
              sonnet-api:
                backend: anthropic
                provider: anthropic
                model: claude-sonnet-5
                supports_vision: true
                max_tokens: 8192
                backend_config:
                  api_key_file: /run/secrets/tiamat-anthropic-api-key

          cc-opus-4-6:
            default_arm: claude_code
            arms:
              claude_code:
                backend: claude_code
                provider: anthropic
                model: claude-opus-4-6
                supports_vision: true


          cc-sonnet-5:
            default_arm: claude_code
            arms:
              claude_code:
                backend: claude_code
                provider: anthropic
                model: claude-sonnet-5
                supports_vision: true


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
                system_prompt:
                  - id: glm-arm-steering
                    text: |
                      You are running as Tiamat's GLM routing arm. The selected model is GLM 5.2.
                max_tokens: 8192
                backend_config:
                  endpoint: https://opencode.ai/zen/go/v1
                  api_key_file: /run/secrets/tiamat-opencode-api-key
      '';
      # Rate card: human-owned per-arm pricing. Keys are provider/model —
      # the same pair usage observations record. Rates confirmed against
      # published prices 2026-07-05; the nightly drift sensor keeps them
      # honest. Subscription-mode dollars are metered-EQUIVALENT burn, not
      # billed dollars.
      tiamatRatecardJson = pkgs.writeText "tiamat-ratecard.json" (
        builtins.toJSON {
          updated_at = "2026-07-05";
          arms = {
            "anthropic/claude-opus-4-6" = {
              pricing_mode = "subscription";
              input_per_mtok = 5;
              output_per_mtok = 25;
              cache = {
                mode = "explicit";
                read_multiplier = 0.1;
                write_multipliers = {
                  "5m" = 1.25;
                  "1h" = 2.0;
                };
                default_write_ttl = "5m";
                refresh_on_hit = true;
              };
              notes = "Served by BOTH the CC subscription arm and the metered opus-api arm; card keys cannot split by backend, so mode follows the dominant (sub) traffic. The API overflow valve is tracked separately by the backend-scoped anthropic-api-monthly constraint. Published Opus 4.6 rates $5/$25.";
            };
            "anthropic/claude-fable-5" = {
              pricing_mode = "subscription";
              input_per_mtok = 10;
              output_per_mtok = 50;
              cache = {
                mode = "explicit";
                read_multiplier = 0.1;
                write_multipliers = {
                  "5m" = 1.25;
                  "1h" = 2.0;
                };
                default_write_ttl = "5m";
                refresh_on_hit = true;
              };
              notes = "Fable 5 via the CC subscription (subsidized window). Burn priced at published API rates $10/$50. The current 50%-of-weekly sub-cap is the anthropic-fable-weekly constraint, not a rate.";
            };
            "anthropic/claude-sonnet-5" = {
              pricing_mode = "subscription";
              input_per_mtok = 3;
              output_per_mtok = 15;
              cache = {
                mode = "explicit";
                read_multiplier = 0.1;
                write_multipliers = {
                  "5m" = 1.25;
                  "1h" = 2.0;
                };
                default_write_ttl = "5m";
                refresh_on_hit = true;
              };
              notes = "Standard rates $3/$15; intro pricing $2/$10 runs through 2026-08-31 — standard chosen so the card doesn't silently undercount after expiry. Serves both cc-sonnet-5 (sub) and anthropic-sonnet-5 (API) profiles.";
            };
            "openai/gpt-5.5" = {
              pricing_mode = "subscription";
              input_per_mtok = 5;
              output_per_mtok = 30;
              cache = {
                mode = "automatic";
                read_multiplier = 0.1;
              };
              notes = "ChatGPT sub via the codex responses backend. Burn priced at published API rates $5/$30, cached input $0.50 (0.1x).";
            };
            "openai/gpt-5.6-sol" = {
              pricing_mode = "subscription";
              input_per_mtok = 5;
              output_per_mtok = 30;
              cache = {
                mode = "automatic";
                read_multiplier = 0.1;
              };
              notes = "ChatGPT sub via codex responses backend. Burn priced same as gpt-5.5 pending published rate confirmation for 5.6-sol.";
            };
            "opencode/glm-5.2" = {
              pricing_mode = "metered";
              input_per_mtok = 1.4;
              output_per_mtok = 4.4;
              cache = {
                mode = "automatic";
                read_multiplier = 0.2;
              };
              notes = "Priced at Z.AI official rates $1.40/$4.40 (cached ~$0.26) as a proxy for opencode zen billing — pending confirmation against an actual opencode invoice.";
            };
            "llama.cpp/qwen3.6-27b" = {
              pricing_mode = "free";
              input_per_mtok = 0;
              output_per_mtok = 0;
              cache = {
                mode = "none";
                read_multiplier = 1;
              };
              notes = "Local llama.cpp; electricity is not modeled.";
            };
            "ollama/qwen3.6-27b" = {
              pricing_mode = "free";
              input_per_mtok = 0;
              output_per_mtok = 0;
              cache = {
                mode = "none";
                read_multiplier = 1;
              };
              notes = "Legacy provider key for the same local model; kept so old usage rows still price.";
            };
          };
        }
      );
      # Economics: constraints are the REAL limits (subscription weekly
      # windows, backend-scoped); API arms are ~$20 overflow valves, not
      # budgets. Sub seats are $2k/mo inference-equivalent, tracked
      # adaptive by the burn factor. Ground truth: briefs/economics-
      # ground-truth.md (2026-07-04).
      tiamatEconomicsJson = pkgs.writeText "tiamat-economics.json" (
        builtins.toJSON {
          lambda_cost = 0.2;
          default_score = 0.5;
          min_count = 1;
          constraints = [
            {
              # Anthropic API arm is an overflow valve (~$20/mo intended);
              # its being used at all is a signal. Backend-scoped so the
              # CC subscription traffic (same provider/model!) never
              # counts against it.
              name = "anthropic-api-monthly";
              providers = [ "anthropic" ];
              backends = [ "anthropic" ];
              budget_usd = 20;
              window = "month";
              kp = 5;
            }
            {
              # Anthropic sub weekly window: $2k/mo equivalent -> ~$460
              # per rolling 168h. The 5h window limits are assumed away
              # by smooth weekly burn per the ground-truth brief.
              name = "anthropic-sub-weekly";
              providers = [ "anthropic" ];
              backends = [ "claude_code" ];
              budget_usd = 460;
              window = "168h";
              kp = 5;
              fill_threshold = 0.8;
            }
            {
              # Current ad-hoc sub-cap: Fable at 50% of weekly. These
              # appear and disappear; delete this block when Anthropic
              # lifts the cap.
              name = "anthropic-fable-weekly";
              providers = [ "anthropic" ];
              backends = [ "claude_code" ];
              models = [ "claude-fable-5" ];
              budget_usd = 230;
              window = "168h";
              kp = 5;
              fill_threshold = 0.8;
            }
            {
              # OpenAI's real constraint is the sub's weekly window, not
              # API dollars (the invented $500/168h API budget is gone —
              # there is no metered OpenAI arm in the live profiles).
              name = "openai-sub-weekly";
              providers = [ "openai" ];
              backends = [ "openai_responses" ];
              budget_usd = 460;
              window = "168h";
              kp = 5;
              fill_threshold = 0.8;
            }
          ];
          subscriptions = [
            {
              provider = "anthropic";
              monthly_usd = 2000;
            }
            {
              provider = "openai";
              monthly_usd = 2000;
            }
          ];
        }
      );
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

      # Kobold worker settings (no secrets here — the bearer token arrives
      # via the overlay's workerTokenEnvFile). work_root lives under
      # tiamat's home so the worker (running as tiamat) can create it.
      config.environment.etc."kobold/worker.json".text = builtins.toJSON {
        url = "https://kobold.gisi.network";
        worker_id = "lordhenry";
        tags = [ "lordhenry" ];
        concurrency = 1;
        shell_path = "/run/overlays/bin:/run/current-system/sw/bin";
        work_root = "/var/lib/tiamat/kobold-worker";
      };

      config.users.groups.grotto = { };
      config.users.users.grotto = {
        isSystemUser = true;
        group = "grotto";
        description = "Grotto service user";
        home = "/home/dev/.local/share/grotto";
        createHome = true;
      };
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
        "d /home/dev/.local/share/grotto 0750 grotto grotto -"
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
        install -D -m 0644 ${tiamatAnthropicSecretDropin} /etc/systemd/system/overlay-tiamat.service.d/10-anthropic-secret-file.conf
        # Pre-flattening unit name (q-b5f9ad4b) — drop the stale drop-in dir
        rm -rf /etc/systemd/system/overlay-tiamat-tiamat.service.d
      '';

      config.systemd.services.tiamat-profiles-provision = {
        description = "Provision Tiamat profile configuration";
        wantedBy = [ "multi-user.target" ];
        before = [ "overlay-tiamat.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          ${pkgs.coreutils}/bin/install -D -o tiamat -g tiamat -m 0440 ${tiamatProfilesYaml} /var/lib/tiamat/profiles.yaml
          ${pkgs.coreutils}/bin/install -D -o tiamat -g tiamat -m 0440 ${tiamatRatecardJson} /var/lib/tiamat/ratecard.json
          ${pkgs.coreutils}/bin/install -D -o tiamat -g tiamat -m 0440 ${tiamatEconomicsJson} /var/lib/tiamat/economics.json
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
