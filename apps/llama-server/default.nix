{ ... }:
{ config, pkgs, lib, ... }:
let
  llama-cpp-cuda = import ../../pkgs/llama-cpp-cuda { inherit pkgs; };
  modelStore = "/var/lib/llama-server/models";
  port = 8012;

  models = [
    {
      repo = "unsloth/Qwen3.6-27B-MTP-GGUF";
      file = "Qwen3.6-27B-Q8_0.gguf";
      sha256 = "9408dcb356cc061a05c139e5647cbde0698ff980c6a69f7fc214e9989f86cfa8";
    }
  ];

  modelsJson = builtins.toJSON models;

  reconcileScript = pkgs.writeShellScript "llama-model-reconcile" ''
    set -uo pipefail

    MODEL_STORE="${modelStore}"

    model_count=$(echo '${modelsJson}' | ${pkgs.jq}/bin/jq 'length')
    failed=0

    for i in $(seq 0 $((model_count - 1))); do
      repo=$(echo '${modelsJson}' | ${pkgs.jq}/bin/jq -r ".[$i].repo")
      file=$(echo '${modelsJson}' | ${pkgs.jq}/bin/jq -r ".[$i].file")
      expected_sha256=$(echo '${modelsJson}' | ${pkgs.jq}/bin/jq -r ".[$i].sha256")

      target="$MODEL_STORE/$file"
      partial="$MODEL_STORE/$file.downloading"
      url="https://huggingface.co/$repo/resolve/main/$file"

      # Already present and valid — skip
      if [ -f "$target" ]; then
        if [ -z "$expected_sha256" ]; then
          echo "OK: $file (no hash configured)"
          continue
        fi
        actual=$(sha256sum "$target" | cut -d' ' -f1)
        if [ "$actual" = "$expected_sha256" ]; then
          echo "OK: $file"
          continue
        else
          echo "WARN: $file hash mismatch (expected $expected_sha256, got $actual). Removing."
          rm -f "$target"
        fi
      fi

      # If partial download is already the right size, try validating it
      # (handles the curl 416 edge case when resume has nothing left to fetch)
      if [ -f "$partial" ] && [ -n "$expected_sha256" ]; then
        actual=$(sha256sum "$partial" | cut -d' ' -f1)
        if [ "$actual" = "$expected_sha256" ]; then
          mv "$partial" "$target"
          echo "DONE: $file (completed partial validated)"
          continue
        fi
      fi

      # Download with resume support
      echo "Downloading: $file from $url"
      if ! ${pkgs.curl}/bin/curl -C - -L --fail --retry 3 --retry-delay 10 \
           --connect-timeout 30 \
           -o "$partial" "$url"; then
        echo "ERROR: Download failed for $file. Will retry next cycle."
        failed=$((failed + 1))
        continue
      fi

      # Validate hash (skip if not configured)
      if [ -n "$expected_sha256" ]; then
        actual=$(sha256sum "$partial" | cut -d' ' -f1)
        if [ "$actual" != "$expected_sha256" ]; then
          echo "ERROR: Hash mismatch for $file (expected $expected_sha256, got $actual). Deleting corrupt file."
          rm -f "$partial"
          failed=$((failed + 1))
          continue
        fi
      fi

      # Atomic rename
      mv "$partial" "$target"
      echo "DONE: $file"
    done

    if [ "$failed" -gt 0 ]; then
      echo "$failed model(s) failed. Will retry next cycle."
      exit 1
    fi

    echo "Model reconciliation complete"
  '';
in
{
  systemd.tmpfiles.rules = [
    "d ${modelStore} 0755 llama-server llama-server -"
  ];

  users.users.llama-server = {
    isSystemUser = true;
    group = "llama-server";
    home = "/var/lib/llama-server";
  };
  users.groups.llama-server = { };

  systemd.services.llama-server = {
    description = "llama.cpp inference server (CUDA)";
    after = [ "network.target" ];
    # Don't start during activation — model reconciliation starts us
    # after downloading GGUFs. Prevents crash-loop failing the switch.
    wantedBy = [ ];

    serviceConfig = {
      Type = "simple";
      User = "llama-server";
      Group = "llama-server";
      StateDirectory = "llama-server";
      ExecStart = lib.concatStringsSep " " [
        "${llama-cpp-cuda}/bin/llama-server"
        "--host 0.0.0.0"
        "--port ${toString port}"
        "--model ${modelStore}/${(builtins.head models).file}"
        "--gpu-layers 999"
        "--ctx-size 32768"
        "--flash-attn"
        "--spec-type draft-mtp"
        "--spec-draft-n-max 3"
      ];
      Restart = "on-failure";
      RestartSec = 5;

      # GPU access
      SupplementaryGroups = [ "video" "render" ];
    };
  };

  # Model reconciliation — download declared GGUFs to the model store
  systemd.timers.llama-server-models = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "30min";
    };
  };

  systemd.services.llama-server-models = {
    description = "Reconcile GGUF model store for llama-server";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "llama-server";
      Group = "llama-server";
      ExecStart = reconcileScript;
      # Restart llama-server after successful model download (runs as root).
      # --no-block avoids deadlock if llama-server has ordering on this unit.
      ExecStartPost = "+${pkgs.systemd}/bin/systemctl restart --no-block llama-server";
    };
  };

  fort.cluster.services = [{
    name = "llama";
    inherit port;
    visibility = "public";
    sso = {
      mode = "token";
      vpnBypass = true;
    };
  }];
}
