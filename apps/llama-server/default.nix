{ ... }:
{ config, pkgs, lib, ... }:
let
  llama-cpp-cuda = import ../../pkgs/llama-cpp-cuda { inherit pkgs; };
  modelStore = "/var/lib/llama-server/models";
  port = 8012;
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
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "llama-server";
      Group = "llama-server";
      StateDirectory = "llama-server";
      ExecStart = lib.concatStringsSep " " [
        "${llama-cpp-cuda}/bin/llama-server"
        "--host 0.0.0.0"
        "--port ${toString port}"
        "--model-store ${modelStore}"
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
