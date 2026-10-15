# Decision-model server: llama.cpp's /v1/systemone on one RTX 3090.
#
# A decision model answers typed questions (choice / noul / score) about a
# state with a probability for every option, in one forward pass, and can only
# answer with options the caller supplied. Consumers: familiar's L1 decider
# (FAMILIAR_L1_DECIDER_URL) and the Connect column/row/USALI mapping prototype.
#
# Default model: vLLM Semantic Router's d3-flash (8.4B, Qwen3.5-9B base,
# Apache-2.0), converted to GGUF by ggml-org. On the community Jev Decision
# Index (read 2026-10-15) it is the strongest open model that fits beside
# Parakeet on a 24 GiB card: 55.8 skill vs 47.6 clef-flash, 52.6 d3-mini,
# 39.5 Kev-4B, 21.3 Strands Decider 2B. Its mmproj adds image state (PDF page
# renders for Connect). Served by stock llama.cpp, so no Python, no container
# and no trust_remote_code.
#
# Exposure is decision-only by construction:
#   llama-server binds 127.0.0.1:${backendPort} and is denied all non-loopback
#   IP traffic (IPAddressDeny), so it cannot reach out either.
#   A loopback-only nginx filter on 127.0.0.1:${port} passes exactly
#   POST /v1/systemone, GET /v1/models and GET /health; everything else
#   (chat/completions, completion, embeddings, props, slots, ...) is a 404.
#   fort exposes that filter as decider.<domain> with visibility "vpn".
{ subdomain ? null
, serviceName ? "decider"
, port ? 8014
, backendPort ? 18014
, gpuDevice ? 1
, model ? {
    repo = "ggml-org/vllm-d3-flash-GGUF";
    file = "vllm-d3-flash-Q8_0.gguf";
    sha256 = "7352edf6be85d93ab8806a17e1b3d0a7e71ee3685af3212ddbe679b742c2221b";
  }
, mmproj ? {
    repo = "ggml-org/vllm-d3-flash-GGUF";
    file = "mmproj-vllm-d3-flash-Q8_0.gguf";
    sha256 = "0291125ad889adb09a0097cc7ba081ce2cfbd2eaf4f253160559da14de93e14c";
  }
, modelAlias ? "vllm-d3-flash"
  # d3 evaluates the whole prompt in one batch, so the ubatch must hold the
  # largest state + question we will send. 8192 covers a column header plus
  # sampled values, or an L1 turn; raise both together if requests 4xx with
  # "increase the physical batch size".
, contextSize ? 16384
, ubatchSize ? 8192
, parallel ? 2
, maxBodySize ? "32m"
, ...
}:
{ config, pkgs, lib, ... }:
let
  llamaPackage = import ../../pkgs/llama-cpp-decision { inherit pkgs; };
  stateDir = "/var/lib/decider";
  modelStore = "${stateDir}/models";
  artifacts = [ model ] ++ lib.optional (mmproj != null) mmproj;
  artifactsJson = builtins.toJSON artifacts;

  reconcileScript = pkgs.writeShellScript "decider-model-reconcile" ''
    set -uo pipefail
    MODEL_STORE="${modelStore}"
    failed=0
    n=$(echo '${artifactsJson}' | ${pkgs.jq}/bin/jq 'length')
    for i in $(seq 0 $((n - 1))); do
      repo=$(echo '${artifactsJson}' | ${pkgs.jq}/bin/jq -r ".[$i].repo")
      file=$(echo '${artifactsJson}' | ${pkgs.jq}/bin/jq -r ".[$i].file")
      want=$(echo '${artifactsJson}' | ${pkgs.jq}/bin/jq -r ".[$i].sha256")
      target="$MODEL_STORE/$file"
      partial="$target.downloading"
      if [ -f "$target" ]; then
        if [ "$(sha256sum "$target" | cut -d' ' -f1)" = "$want" ]; then
          echo "OK: $file"; continue
        fi
        echo "WARN: $file hash mismatch, removing"; rm -f "$target"
      fi
      echo "Downloading: $file"
      if ! ${pkgs.curl}/bin/curl -C - -L --fail --retry 3 --retry-delay 10 \
           --connect-timeout 30 -o "$partial" \
           "https://huggingface.co/$repo/resolve/main/$file"; then
        echo "ERROR: download failed for $file"; failed=$((failed + 1)); continue
      fi
      if [ "$(sha256sum "$partial" | cut -d' ' -f1)" != "$want" ]; then
        echo "ERROR: hash mismatch for $file, deleting"; rm -f "$partial"
        failed=$((failed + 1)); continue
      fi
      mv "$partial" "$target"; echo "DONE: $file"
    done
    [ "$failed" -eq 0 ] || exit 1
  '';

  allArtifactsPresent = lib.concatMapStringsSep " && " (a: "test -f ${modelStore}/${a.file}") artifacts;
in
{
  users.users.decider = {
    isSystemUser = true;
    group = "decider";
    home = stateDir;
  };
  users.groups.decider = { };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 decider decider -"
    "d ${modelStore} 0755 decider decider -"
  ];

  systemd.services.decider = {
    description = "Decision-model server (llama.cpp /v1/systemone, ${modelAlias})";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    # Weights arrive via decider-models; until then, stay down quietly instead
    # of crash-looping during activation.
    unitConfig.ConditionPathExists = map (a: "${modelStore}/${a.file}") artifacts;

    serviceConfig = {
      Type = "simple";
      User = "decider";
      Group = "decider";
      ExecStart = lib.concatStringsSep " " ([
        "${llamaPackage}/bin/llama-server"
        "--host 127.0.0.1"
        "--port ${toString backendPort}"
        "--model ${modelStore}/${model.file}"
        "--alias ${modelAlias}"
        "--ctx-size ${toString contextSize}"
        "--batch-size ${toString ubatchSize}"
        "--ubatch-size ${toString ubatchSize}"
        "--parallel ${toString parallel}"
        "--gpu-layers 999"
        "--flash-attn on"
        "--no-webui"
        "--no-slots"
      ] ++ lib.optional (mmproj != null) "--mmproj ${modelStore}/${mmproj.file}");
      Restart = "on-failure";
      RestartSec = 5;
      # CUDA_VISIBLE_DEVICES applies before CUDA initializes: this process sees
      # only the one card and cannot spill onto GPU 0 (qwen-vllm).
      Environment = [ "CUDA_VISIBLE_DEVICES=${toString gpuDevice}" ];
      SupplementaryGroups = [ "video" "render" ];
      # Loopback only, in and out.
      IPAddressDeny = "any";
      IPAddressAllow = "localhost";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadOnlyPaths = [ modelStore ];
      PrivateTmp = true;
    };
  };

  systemd.services.decider-models = {
    description = "Reconcile decision-model GGUFs";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      User = "decider";
      Group = "decider";
      ExecStart = reconcileScript;
      # Root ExecStartPost: (re)start the server once weights verify. --no-block
      # so a long first download never wedges activation.
      ExecStartPost = "+${pkgs.bash}/bin/bash -c '${allArtifactsPresent} && ${pkgs.systemd}/bin/systemctl restart --no-block decider.service'";
    };
  };

  systemd.timers.decider-models = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "6h";
    };
  };

  # Decision-only filter in front of llama-server. Loopback listener; the fort
  # vhost below is the only way in from the network.
  services.nginx.enable = true;
  services.nginx.virtualHosts."decider-filter" = {
    listen = [{ addr = "127.0.0.1"; port = port; }];
    extraConfig = ''
      client_max_body_size ${maxBodySize};
    '';
    locations."= /v1/systemone" = {
      proxyPass = "http://127.0.0.1:${toString backendPort}";
      extraConfig = ''
        limit_except POST { deny all; }
        proxy_read_timeout 120s;
      '';
    };
    locations."= /v1/models" = {
      proxyPass = "http://127.0.0.1:${toString backendPort}";
      extraConfig = "limit_except GET { deny all; }";
    };
    locations."= /health" = {
      proxyPass = "http://127.0.0.1:${toString backendPort}";
      extraConfig = "limit_except GET { deny all; }";
    };
    locations."/".return = "404";
  };

  fort.cluster.services = [{
    name = serviceName;
    inherit port subdomain maxBodySize;
    visibility = "vpn";
    sso.mode = "none";
    health.endpoint = "/health";
  }];
}
