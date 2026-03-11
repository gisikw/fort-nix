# Raspberry Pi 5 Provisioning

## Hardware Prep

1. Flash a NixOS aarch64 minimal ISO to a microSD card (or NVMe via USB adapter)
2. Boot the Pi, connect via HDMI+keyboard or find its IP on the network
3. Enable SSH for remote provisioning:
   ```bash
   passwd root    # set a temporary password
   ```
4. Get the IP: `ip a`

## Provisioning

From the fort-nix repo root:

```bash
just provision raspberry-pi-5 <ip-address>
```

## Disk Notes

- Default disk device is `/dev/mmcblk0` (microSD)
- For NVMe (via HAT or M.2 adapter), override in the device manifest:
  ```nix
  disko.devices.disk.main.device = "/dev/nvme0n1";
  ```
- Boot partition mounts at `/boot/firmware` (extlinux bootloader)

## Gotchas

- **No UEFI/GRUB**: Pi 5 uses extlinux-compatible bootloader, not GRUB
- **Kernel**: Uses `linuxPackages_rpi5` — mainline doesn't fully support Pi 5 hardware
- **Cross-compilation**: Building on x86_64 requires either an aarch64 builder or `binfmt` emulation
- **Wireless firmware**: Included via `raspberrypiWirelessFirmware`, but onboard WiFi may need additional config for your network
