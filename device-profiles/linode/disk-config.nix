{ lib, ... }:

{
  disko.devices = {
    disk.disk1 = {
      device = lib.mkDefault "/dev/sda";
      type = "disk";
      content = {
        type = "filesystem";
        format = "ext4";
        mountpoint = "/";
      };
    };

    disk.disk2 = {
      device = lib.mkDefault "/dev/sdb";
      type = "disk";
      content = {
        type = "swap";
        randomEncryption = false;
      };
    };
  };
}
