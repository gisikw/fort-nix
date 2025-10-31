{ lib, ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = lib.mkDefault "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
          };
        };
        persist = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [ "-f" ];
            subvolumes = {
              "@nix" = {
                mountpoint = "/nix";
                mountOptions = [ "noatime" ];
              };
              "@system" = {
                mountpoint = "/persist/system";
              };
              "@home" = {
                mountpoint = "/home";
              };
            };
          };
        };
      };
    };
  };
}
