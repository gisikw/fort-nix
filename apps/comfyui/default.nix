{ subdomain ? null, rootManifest, ... }:
{ config, pkgs, lib, ... }:
let
  fort = rootManifest.fortConfig;
  domain = fort.settings.domain;

  # Pre-start script: installs custom nodes on first container boot.
  # Runs before ComfyUI launches (sourced by entrypoint.sh).
  preStartScript = pkgs.writeText "comfyui-pre-start.sh" ''
    #!/bin/bash
    set -eu

    CUSTOM_NODES_DIR="/root/ComfyUI/custom_nodes"

    # ComfyUI-RMBG: background removal (RMBG-2.0, BiRefNet, BEN2, etc.)
    # PyTorch-based models run GPU-accelerated via ROCm; skip onnxruntime-gpu
    # which is CUDA-only and not needed for the models we use.
    if [ ! -d "''${CUSTOM_NODES_DIR}/ComfyUI-RMBG" ]; then
        echo "[pre-start] Installing ComfyUI-RMBG..."
        cd "''${CUSTOM_NODES_DIR}"
        git clone https://github.com/1038lab/ComfyUI-RMBG.git
        cd ComfyUI-RMBG
        # Install deps but replace onnxruntime-gpu (CUDA-only) with CPU fallback
        sed 's/onnxruntime-gpu/onnxruntime/' requirements.txt | pip install -r /dev/stdin
        echo "[pre-start] ComfyUI-RMBG installed."
    else
        echo "[pre-start] ComfyUI-RMBG already installed."
    fi
  '';

  logoWorkflow = ./logo-workflow.json;
in
{
  virtualisation.oci-containers.containers.comfyui = {
    image = "containers.${domain}/yanwk/comfyui-boot:rocm6";
    ports = [ "127.0.0.1:8188:8188" ];
    environment = {
      # Radeon 8060S: HIP reports gfx1102, HSA reports gfx1151
      HSA_OVERRIDE_GFX_VERSION = "11.0.0";
      HCC_AMDGPU_TARGET = "gfx1151";
      PYTORCH_HIP_ALLOC_CONF = "expandable_segments:True";
    };
    extraOptions = [
      "--device=/dev/kfd"
      "--device=/dev/dri"
      "--group-add=video"
    ];
    volumes = [
      "/var/lib/comfyui/root:/root"
      "/var/lib/comfyui/models:/root/ComfyUI/models"
      "/var/lib/comfyui/hf-cache:/root/.cache/huggingface/hub"
      "/var/lib/comfyui/torch-cache:/root/.cache/torch/hub"
      "/var/lib/comfyui/input:/root/ComfyUI/input"
      "/var/lib/comfyui/output:/root/ComfyUI/output"
      "/var/lib/comfyui/workflows:/root/ComfyUI/user/default/workflows"
    ];
  };

  # Deploy pre-start script and workflow into the container's persistent storage.
  # The container's entrypoint sources user-scripts/pre-start.sh before launching.
  systemd.services.comfyui-setup = {
    description = "Deploy ComfyUI workflows and pre-start script";
    wantedBy = [ "multi-user.target" ];
    before = [ "podman-comfyui.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Pre-start script for custom node installation
      mkdir -p /var/lib/comfyui/root/user-scripts
      cp ${preStartScript} /var/lib/comfyui/root/user-scripts/pre-start.sh
      chmod +x /var/lib/comfyui/root/user-scripts/pre-start.sh

      # Logo generation workflow
      mkdir -p /var/lib/comfyui/workflows
      cp ${logoWorkflow} /var/lib/comfyui/workflows/logo-generation.json
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/comfyui 0755 root root -"
    "d /var/lib/comfyui/root 0755 root root -"
    "d /var/lib/comfyui/models 0755 root root -"
    "d /var/lib/comfyui/hf-cache 0755 root root -"
    "d /var/lib/comfyui/torch-cache 0755 root root -"
    "d /var/lib/comfyui/input 0755 root root -"
    "d /var/lib/comfyui/output 0755 root root -"
    "d /var/lib/comfyui/workflows 0755 root root -"
  ];

  fort.cluster.services = [
    {
      name = "comfyui";
      subdomain = subdomain;
      port = 8188;
      visibility = "vpn";
      sso.mode = "none";
      maxBodySize = "100m";
    }
  ];
}
