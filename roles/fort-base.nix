{ config, fort, lib, pkgs, ... }:
let
  domain = fort.settings.domain;
  tailscaleSecretCandidates = [
    "${../secrets}/tailscale-${fort.host}.age"
    "${../secrets}/tailscale-default.age"
  ];
  tailscaleSecretFile = lib.findFirst builtins.pathExists null tailscaleSecretCandidates;
  hasTailscaleSecret = tailscaleSecretFile != null;
  tailscaleSecretName = if tailscaleSecretFile == "${../secrets}/tailscale-default.age" then
    "tailscale-shared-auth-key"
  else
    "tailscale-${fort.host}-auth-key";
in
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.systemPackages = [ pkgs.neovim pkgs.tailscale ];

  age.secrets = lib.mkIf hasTailscaleSecret {
    "${tailscaleSecretName}" = {
      file = tailscaleSecretFile;
      mode = "0400";
    };
  };

  services.tailscale =
    {
      enable = true;
      useRoutingFeatures = "client";
      extraUpFlags = [
        "--login-server=https://ts.${domain}"
        "--hostname=${fort.host}"
        "--accept-dns=true"
        "--accept-routes=true"
      ];
    }
    // lib.optionalAttrs hasTailscaleSecret {
      authKeyFile = config.age.secrets."${tailscaleSecretName}".path;
    };
}
