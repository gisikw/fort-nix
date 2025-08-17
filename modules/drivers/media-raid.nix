{ config, lib, pkgs, fort, ... }:
{
  boot.supportedFilesystems = [ "zfs" ];

  boot.initrd.kernelModules = [ "zfs" ];
  boot.kernelModules = [ "zfs" ];

  networking.hostId = builtins.substring 0 8 fort.device;

  boot.zfs = {
    extraPools = [ "media" ];
    forceImportRoot = true;
    forceImportAll = true;
  };

  services.zfs.trim.enable = true;

  environment.systemPackages = with pkgs; [ zfs ];
}
