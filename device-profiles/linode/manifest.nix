{
  system = "x86_64-linux";
  impermanent = false;
  module =
    { modulesPath, config, ... }:
    {
      imports = [
        "${modulesPath}/profiles/qemu-guest.nix"
        ./disk-config.nix
      ];

      boot.initrd.availableKernelModules = [
        "virtio_pci"
        "virtio_scsi"
        "ahci"
        "sd_mod"
      ];
      boot.kernelParams = [ "console=ttyS0,19200n8" ];
      boot.loader.grub.extraConfig = ''
        serial --speed=19200 --unit=0 --word=8 --parity=no --stop=1;
        terminal_input serial;
        terminal_output serial
      '';
      boot.loader.grub.forceInstall = true;
      boot.loader.grub.device = "nodev";
      boot.loader.timeout = 2;

      services.openssh.enable = true;

      users.mutableUsers = false;
      users.users.root.initialPassword = "hunter2";
      users.users.root.openssh.authorizedKeys.keys = [ config.fort.settings.principals.admin.publicKey ];

      # Linode requires per-interface DHCP due to global DHCP being disabled.
      networking.interfaces.eth0.useDHCP = true;
      networking.useDHCP = false;

      # fileSystems."/" = {
      #   device = "/dev/sda";
      #   fsType = "ext4";
      # };

      # swapDevices = [
      #   { device = "/dev/sdb"; }
      # ];
    };
}
