{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Protectli V1410 — Intel N5105 (Jasper Lake)
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"   # eMMC
  ];
  boot.kernelModules = [ "kvm-intel" ];

  # NVMe boot drive (partitioned by install.sh)
  fileSystems."/" = {
    device = "/dev/disk/by-label/CORE-ROOT";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/CORE-BOOT";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  # Intel N5105
  hardware.cpu.intel.updateMicrocode = true;
  powerManagement.cpuFreqGovernor = "ondemand";

  # 4x Intel I226-V 2.5GbE NICs
  # Rename to stable names via udev rules (MAC-based)
  # Set actual MACs after hardware arrives and run `ip link`
  #
  # NIC1 → wan0 (to Spectrum modem)
  # NIC2 → lan0 (to switch, serves LAN)
  # NIC3 → spare (VLAN segmentation, future)
  # NIC4 → spare
  services.udev.extraRules = ''
    # TODO: set MAC addresses from actual hardware
    # SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="aa:bb:cc:dd:ee:01", NAME="wan0"
    # SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="aa:bb:cc:dd:ee:02", NAME="lan0"
  '';

  # WAN: DHCP from Spectrum modem
  networking.interfaces.wan0 = {
    useDHCP = true;
  };

  # LAN: static IP, this is the gateway
  networking.interfaces.lan0 = {
    ipv4.addresses = [{
      address = "192.168.1.1";
      prefixLength = 24;
    }];
  };

  # Don't use networkmanager — we manage interfaces directly
  networking.useDHCP = false;
}
