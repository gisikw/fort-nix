{ ... }:
{ config, pkgs, lib, ... }:
let
  ollama-vulkan-latest = pkgs.ollama-vulkan.overrideAttrs (old: rec {
    version = "0.23.0";
    src = old.src.override {
      tag = "v${version}";
      hash = "sha256-VYaFCSqhIlJPJv1SUiNDgSzLqySK3NTfucdWA7IZaAk=";
    };
    vendorHash = "sha256-1ndXnef1siLKrC0SyAcZmfN8p9pjcOMvcc/boTwBzGc=";
    subPackages = [ "." ];
  });

  ollama = ollama-vulkan-latest;

  dashboard = ./dashboard.py;
  dashboardPort = 11435;

  # Models to reconcile. Three forms:
  #   "qwen3:30b-a3b-q8_0"                                              — pull from registry
  #   { name = "tuned"; from = "qwen3:30b-a3b-q8_0"; params = {...}; }  — Modelfile from tag
  #   { name = "heretic"; fromGguf = { url = "..."; sha256 = "..."; };   — Modelfile from GGUF
  #     params = {...}; renderer = "gemma4"; parser = "gemma4"; }
  models = [
    "devstral-small-2:latest"
    "nomic-embed-text:latest"
    "gpt-oss:20b"
    "gpt-oss:120b"
    "gemma4:31b"
    "hf.co/LatitudeGames/Wayfarer-2-12B-GGUF:Q4_K_M"
    "hf.co/mradermacher/Mistral-Nemo-Instruct-2407-abliterated-GGUF:Q4_K_M"
    "hf.co/mradermacher/patricide-12B-Unslop-Mell-GGUF:Q4_K_M"
    "phi:latest"
    "qwen3:30b-a3b-q8_0"
    "qwen3.5:4b"
    "qwen3.6:27b"
    {
      name = "gemma4-heretic";
      fromGguf = {
        url = "https://huggingface.co/mradermacher/gemma-4-26B-A4B-it-uncensored-heretic-GGUF/resolve/main/gemma-4-26B-A4B-it-uncensored-heretic.Q4_K_M.gguf";
        sha256 = "0e345c1fbb9f376828c5c3a986c62f6b4b0934e32cf57238ff8960529417d9fb";
      };
      template = "{{ .Prompt }}";
      renderer = "gemma4";
      parser = "gemma4";
      params = {
        top_k = 64;
        top_p = 0.95;
        num_ctx = 262144;
        stop = "<turn|>";
        temperature = 1;
      };
    }
  ];

  ggufDir = "/var/lib/ollama/gguf";

  # Build a Modelfile from a FROM line + optional directives
  mkModelfile = name: fromLine: m:
    pkgs.writeText "Modelfile-${name}" (lib.concatStringsSep "\n" (
      [ fromLine ]
      ++ lib.mapAttrsToList (k: v: "PARAMETER ${k} ${toString v}") (m.params or {})
      ++ lib.optional (m ? system) "SYSTEM \"\"\"${m.system}\"\"\""
      ++ lib.optional (m ? template) "TEMPLATE \"\"\"${m.template}\"\"\""
      ++ lib.optional (m ? renderer) "RENDERER ${m.renderer}"
      ++ lib.optional (m ? parser) "PARSER ${m.parser}"
    ));

  normalizeModel = m:
    if builtins.isString m then {
      name = m;
      type = "pull";
    } else if m ? fromGguf then {
      inherit (m) name fromGguf;
      type = "gguf";
      modelfile = mkModelfile m.name "FROM ${ggufDir}/${m.name}.gguf" m;
    } else {
      inherit (m) name from;
      type = "modelfile";
      modelfile = mkModelfile m.name "FROM ${m.from}" m;
    };

  normalized = map normalizeModel models;
  pulls = lib.filter (m: m.type == "pull") normalized;
  ggufs = lib.filter (m: m.type == "gguf") normalized;
  creates = lib.filter (m: m.type == "modelfile" || m.type == "gguf") normalized;

  api = "http://127.0.0.1:11434";

  reconcileScript = pkgs.writeShellScript "ollama-model-reconcile" ''
    set -euo pipefail

    # Wait for ollama API to be ready
    for i in $(seq 1 60); do
      curl -sf ${api}/api/tags >/dev/null && break
      sleep 2
    done

    EXISTING=$(curl -sf ${api}/api/tags | ${pkgs.jq}/bin/jq -r '.models[].name')
    echo "Existing models:"
    echo "$EXISTING" | sed 's/^/  /'

    # Phase 1: Pull registry models
    ${lib.concatStringsSep "\n" (map (m: ''
      if echo "$EXISTING" | grep -qF "${m.name}"; then
        echo "${m.name}: already present"
      else
        echo "${m.name}: pulling..."
        curl -sf ${api}/api/pull -d '{"name":"${m.name}","stream":false}' >/dev/null
        echo "${m.name}: done"
      fi
    '') pulls)}

    # Phase 2: Download GGUFs
    ${lib.optionalString (ggufs != []) "mkdir -p ${ggufDir}"}
    ${lib.concatStringsSep "\n" (map (m: ''
      GGUF_TARGET="${ggufDir}/${m.name}.gguf"
      if [ -f "$GGUF_TARGET" ] && [ "$(sha256sum "$GGUF_TARGET" | cut -d' ' -f1)" = "${m.fromGguf.sha256}" ]; then
        echo "${m.name}: GGUF present, hash OK"
      else
        echo "${m.name}: downloading GGUF..."
        curl -L -C - -o "$GGUF_TARGET" "${m.fromGguf.url}"
        ACTUAL=$(sha256sum "$GGUF_TARGET" | cut -d' ' -f1)
        if [ "$ACTUAL" != "${m.fromGguf.sha256}" ]; then
          echo "${m.name}: HASH MISMATCH! expected ${m.fromGguf.sha256}, got $ACTUAL"
          rm -f "$GGUF_TARGET"
          exit 1
        fi
        echo "${m.name}: download complete, hash verified"
      fi
    '') ggufs)}

    # Phase 3: Create Modelfile-based models (non-fatal — one bad model shouldn't block the rest)
    FAILURES=0
    ${lib.concatStringsSep "\n" (map (m: ''
      echo "${m.name}: creating from Modelfile..."
      MODELFILE=$(cat ${m.modelfile})
      if curl -sf ${api}/api/create \
        -d "$(${pkgs.jq}/bin/jq -n --arg name "${m.name}" --arg mf "$MODELFILE" '{name:$name,modelfile:$mf,stream:false}')" \
        >/dev/null; then
        echo "${m.name}: done"
      else
        echo "${m.name}: FAILED (curl exit $?)"
        FAILURES=$((FAILURES + 1))
      fi
    '') creates)}

    if [ "$FAILURES" -gt 0 ]; then
      echo "Model reconciliation complete with $FAILURES failure(s)"
    else
      echo "Model reconciliation complete"
    fi
  '';
in
{
  hardware.graphics.enable = true;

  services.ollama = {
    enable = true;
    acceleration = false;
    package = ollama-vulkan-latest;
    openFirewall = false;
  };

  systemd.services.ollama = {
    serviceConfig = {
      Environment = [
        "OLLAMA_HOST=0.0.0.0:11434"
        "OLLAMA_CONTEXT_LENGTH=32768"
        "OLLAMA_USE_MMAP=true"
        "OLLAMA_KEEP_ALIVE=-1"
        "OLLAMA_FLASH_ATTENTION=1"
        "OLLAMA_KV_CACHE_TYPE=q8_0"
      ];
    };
  };

  systemd.services.ollama-dashboard = {
    description = "Ollama GPU dashboard";
    after = [ "ollama.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${dashboard}";
      Environment = [
        "OLLAMA_URL=http://127.0.0.1:11434"
        "DASHBOARD_PORT=${toString dashboardPort}"
      ];
      Restart = "on-failure";
      RestartSec = 2;
    };
    path = [ "/run/current-system/sw" ];
  };

  # Model reconciliation — pull/create declared models
  systemd.timers.ollama-models = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "30min";
    };
  };

  systemd.services.ollama-models = {
    description = "Ollama model reconciliation";
    after = [ "ollama.service" ];
    requires = [ "ollama.service" ];
    path = [ pkgs.coreutils pkgs.gnugrep pkgs.curl pkgs.jq ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = reconcileScript;
      TimeoutSec = "infinity";
    };
    restartIfChanged = false;
  };

  fort.cluster.services = [
    {
      name = "ollama";
      port = 11434;
      visibility = "public";
      sso = {
        mode = "token";
        vpnBypass = true;
      };
    }
    {
      name = "ollama-dashboard";
      subdomain = "gpu";
      port = dashboardPort;
      visibility = "vpn";
      sso.mode = "none";
    }
  ];
}
