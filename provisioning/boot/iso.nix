{ config, lib, pkgs, bootstrapSecret, provisionURL ? "https://provision.gisi.network", ... }:
{
  image.baseName = lib.mkForce "fort-autoprovision";
  isoImage.volumeID = "FORT_PROVISION";

  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];
  networking.networkmanager.enable = true;
  networking.wireless.enable = lib.mkForce false;
  services.openssh.enable = false;
  services.getty.autologinUser = lib.mkForce "root";

  environment.systemPackages = with pkgs; [
    curl
    jq
    git
    nix
    python3
    openssh
    gnutar
    gzip
    nixos-install-tools
  ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.etc."fort-provision/bootstrap-secret" = {
    mode = "0400";
    text = bootstrapSecret;
  };
  environment.etc."fort-provision/client.sh" = {
    mode = "0500";
    source = ./client.sh;
  };

  systemd.services.fort-autoprovision = {
    description = "Fort unattended provisioning client";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment.FORT_PROVISION_URL = provisionURL;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash /etc/fort-provision/client.sh";
      StandardInput = "null";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  systemd.services."getty@tty1".enable = false;
  system.stateVersion = "25.11";
}
