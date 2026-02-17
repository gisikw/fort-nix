{ subdomain ? null, rootManifest, ... }:
{ config, pkgs, lib, ... }:
let
  fort = rootManifest.fortConfig;
  domain = fort.settings.domain;
in
{
  virtualisation.oci-containers.containers.comfyui = {
    image = "containers.${domain}/docker.io/yanwk/comfyui-boot:rocm";
    ports = [ "127.0.0.1:8188:8188" ];
    environment = {
      # Radeon 8060S: HIP reports gfx1102, HSA reports gfx1151
      HSA_OVERRIDE_GFX_VERSION = "11.0.2";
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
    }
  ];
}
