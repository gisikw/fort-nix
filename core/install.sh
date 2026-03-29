#!/usr/bin/env bash
set -euo pipefail

# Core Box Installer
# Runs from the live USB. Installs NixOS to NVMe, copies secrets, wipes USB.

NVME="/dev/nvme0n1"
CORE_SYSTEM="/etc/core-system"

echo "==> Core Box Installer"
echo ""

# --- Detect hardware ---
if [ ! -b "$NVME" ]; then
    echo "ERROR: NVMe drive not found at $NVME"
    echo ""
    echo "Available block devices:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
    exit 1
fi

# Find the USB we booted from
BOOT_DEV=$(findmnt -n -o SOURCE / | sed 's/p\?[0-9]*$//')
echo "Boot media:  $BOOT_DEV"
echo "Target:      $NVME"
echo ""

# --- Find and mount secrets partition ---
SECRETS_MNT=""
SECRETS_PART=$(blkid -L CORE-SECRETS 2>/dev/null || true)
if [ -n "$SECRETS_PART" ]; then
    SECRETS_MNT=$(mktemp -d)
    mount -o ro "$SECRETS_PART" "$SECRETS_MNT"
    echo "Secrets:     $SECRETS_PART (mounted)"
else
    echo "WARNING: No CORE-SECRETS partition found on USB."
    echo "You will need to install secrets manually after boot."
    read -p "Continue anyway? [y/N] " CONT
    [ "$CONT" = "y" ] || exit 1
fi

# --- Confirm ---
echo ""
echo "This will ERASE $NVME and install the core system."
echo "After install, $BOOT_DEV will be WIPED (self-destructing media)."
echo ""
read -p "Type 'yes' to continue: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

# --- Partition NVMe ---
echo ""
echo "==> Partitioning $NVME..."
parted -s "$NVME" -- mklabel gpt
parted -s "$NVME" -- mkpart ESP fat32 1MiB 512MiB
parted -s "$NVME" -- set 1 esp on
parted -s "$NVME" -- mkpart root ext4 512MiB 100%

echo "==> Formatting..."
mkfs.fat -F 32 -n CORE-BOOT "${NVME}p1"
mkfs.ext4 -L CORE-ROOT "${NVME}p2"

echo "==> Mounting..."
mount "${NVME}p2" /mnt
mkdir -p /mnt/boot
mount "${NVME}p1" /mnt/boot

# --- Install NixOS ---
echo "==> Installing NixOS (this may take a few minutes)..."
nixos-install --system "$CORE_SYSTEM" --no-root-passwd --no-channel-copy

# --- Copy secrets ---
if [ -n "$SECRETS_MNT" ]; then
    echo "==> Installing secrets..."
    mkdir -p /mnt/var/lib/core
    cp "$SECRETS_MNT/master-key" /mnt/var/lib/core/master-key
    cp "$SECRETS_MNT/master-key.pub" /mnt/var/lib/core/master-key.pub
    cp "$SECRETS_MNT/registrar.env" /mnt/var/lib/core/registrar.env
    chmod 600 /mnt/var/lib/core/master-key /mnt/var/lib/core/registrar.env
    chmod 644 /mnt/var/lib/core/master-key.pub

    # FIDO2 keys → root's authorized_keys
    if [ -f "$SECRETS_MNT/fido2-keys" ]; then
        mkdir -p /mnt/root/.ssh
        cp "$SECRETS_MNT/fido2-keys" /mnt/root/.ssh/authorized_keys
        chmod 700 /mnt/root/.ssh
        chmod 600 /mnt/root/.ssh/authorized_keys
    fi

    # Master pubkey → git user authorized_keys (for push access)
    mkdir -p /mnt/var/lib/core-git
    umount "$SECRETS_MNT"
    rmdir "$SECRETS_MNT"
fi

# --- Unmount target ---
echo "==> Finalizing..."
umount /mnt/boot
umount /mnt

# --- Self-destruct: wipe the USB ---
echo "==> Wiping boot media ($BOOT_DEV)..."
dd if=/dev/zero of="$BOOT_DEV" bs=4M count=100 status=progress 2>/dev/null || true
sync

echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║  Installation complete.                        ║"
echo "║                                                ║"
echo "║  Remove USB and reboot.                        ║"
echo "║                                                ║"
echo "║  The USB has been wiped.                       ║"
echo "║  The master key exists only on NVMe now.       ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
read -p "Press Enter to reboot..." _
reboot
