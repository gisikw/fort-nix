# Known to work with NixOS 25.05 onto Ubuntu 24.04 LTS configuration on a Linode 2 GB

{ config, lib, pkgs, modulesPath, fort, ... }: {
  system.stateVersion = "25.05";

  imports = [
    "${modulesPath}/profiles/qemu-guest.nix" 
    ./disk-config.nix
  ];

  boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_scsi" "ahci" "sd_mod" ];
  boot.kernelParams = [ "console=ttyS0,19200n8" ];
  boot.loader.grub.extraConfig = ''
    serial --speed=19200 --unit=0 --word=8 --parity=no --stop=1;
    terminal_input serial;
    terminal_output serial
  '';
  boot.loader.grub.forceInstall = true;
  boot.loader.grub.device = "nodev";
  boot.loader.timeout = 10;

  fileSystems."/" = {
    device = "/dev/sda";
    fsType = "ext4";
  };

  swapDevices = [
    { device = "/dev/sdb"; }
  ];

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  users.users.root.openssh.authorizedKeys.keys = [ fort.settings.pubkey ];

  # Linode requires per-interface DHCP due to global DHCP being disabled.
  networking.interfaces.eth0.useDHCP = true;
  networking.useDHCP = false;

  users.users.root.extraGroups = [ "networkmanager" ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
