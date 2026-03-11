{
  platform = "nixos";
  system = "aarch64-linux";
  impermanent = false;
  module =
    { config, lib, modulesPath, pkgs, ... }:
    {
      imports = [
        (modulesPath + "/installer/scan/not-detected.nix")
        ./disk-config.nix
      ];

      # Pi 5 kernel and firmware
      boot.kernelPackages = pkgs.linuxPackages_rpi5;
      hardware.raspberry-pi."5".enable = true;
      hardware.deviceTree.enable = true;

      boot.loader = {
        grub.enable = false;
        generic-extlinux-compatible.enable = true;
      };

      # Hardware support
      hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ];
      hardware.enableRedistributableFirmware = true;

      services.openssh.enable = true;

      users.mutableUsers = false;
      users.users.root.initialPassword = "hunter2";
      users.users.root.openssh.authorizedKeys.keys = [ config.fort.cluster.settings.principals.admin.publicKey ];
    };
}
