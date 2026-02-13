# Linode VPS Provisioning

## Linode Dashboard Setup

1. Create a new Linode (must be the **2GB RAM** plan minimum)
2. Select **Ubuntu 24.04 LTS** as the image
3. Disk layout:
   - 1x ext4 disk (primary)
   - 1x 512MB swap
4. **Resize trick**: create at a small disk size, resize the Linode up, then
   resize it back down — don't resize the disk itself. This gives you the disk
   layout nixos-anywhere expects.
5. Do **not** use impermanence (Linode doesn't support the tmpfs root pattern)

## OS Prep

The Linode boots with SSH already enabled. Just set a root password via the
Linode dashboard or Lish console if needed.

Get the IP from the Linode dashboard → Networking tab.

## Provisioning (from a machine with deploy keys)

From the fort-nix repo root:

```bash
just provision linode <ip-address>
```

This uses a Linode-specific fingerprinting path (reads the Linode ID rather
than DMI UUID). You'll be prompted for the root password during bootstrap.

## Post-Provision

- Assign the device to a host: `just assign <device-uuid> <hostname>`
- First deploy: push to release branch (gitops) or use deploy-rs

## Gotchas

- Linode devices use `networking.interfaces.eth0.useDHCP = true` with global
  DHCP disabled — this is required by Linode's network config
- No impermanence support — state lives on the ext4 root directly
