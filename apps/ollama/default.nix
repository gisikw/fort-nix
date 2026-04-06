{ ... }:
{ config, pkgs, lib, ... }:
let
  ollama-vulkan-latest = pkgs.ollama-vulkan.overrideAttrs (old: rec {
    version = "0.20.0";
    src = old.src.override {
      tag = "v${version}";
      hash = "sha256-QQKPXdXlsT+uMGGIyqkVZqk6OTa7VHrwDVmgDdgdKOY=";
    };
    vendorHash = "sha256-1ndXnef1siLKrC0SyAcZmfN8p9pjcOMvcc/boTwBzGc=";
    # 0.20.0 added x/imagegen and x/mlxrunner subpackages with tree-sitter
    # CGo deps whose C sources aren't in the Go vendor directory.
    # Only build the main binary — MLX/imagegen aren't needed on Vulkan.
    subPackages = [ "." ];
  });

  dashboard = ./dashboard.py;
  dashboardPort = 11435;
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
