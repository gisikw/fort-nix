{
  extraPools ? [ ],
  deviceManifest,
  ...
}:
{
  pkgs,
  config,
  lib,
  ...
}:
let
  zfsInstalled = builtins.pathExists "/run/current-system/kernel-modules/lib/modules/${config.boot.kernelPackages.kernel.version}/extra/zfs.ko.xz";
in
{
  boot.supportedFilesystems = [ "zfs" ];

  boot.initrd.kernelModules = [ "zfs" ];
  boot.kernelModules = [ "zfs" ];

  # Deterministic host id for reproducible zfs imports
  networking.hostId = builtins.substring 0 8 deviceManifest.uuid;

  # Custom import so we don't try to import if the kernel module isn't yet loaded (reboot)
  systemd.services.zfs-late-import = {
    description = "Late ZFS import after module load";
    after = [ "zfs-import.target" ];
    wants = [ "zfs-import.target" ];
    path = [
      pkgs.kmod
      pkgs.zfs
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "zfs-late-import" ''
        echo "[zfs] checking for zfs module..."
        if modinfo zfs >/dev/null 2>&1; then
          echo "[zfs] module present, attempting import"
          for pool in ${lib.concatStringsSep " " extraPools}; do
            if zpool list -H -o name 2>/dev/null | grep -qx "$pool"; then
              echo "[zfs] $pool already imported"
            else
              zpool import -N "$pool" 2>/dev/null \
                && echo "[zfs] imported $pool" \
                || echo "[zfs] $pool not importable"
            fi
          done
        else
          echo "[zfs] module not present yet; skipping import (needs reboot)"
          exit 0
        fi
        echo "[zfs] mounting all datasets"
        zfs mount -a || echo "[zfs] warning: mount failed"
      '';
    };
    wantedBy = [ "multi-user.target" ];
  };

  services.zfs.trim.enable = true;
  environment.systemPackages = with pkgs; [ zfs ];
}
