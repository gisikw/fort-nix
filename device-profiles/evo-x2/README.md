# EVO X2 Provisioning

## BIOS Setup (keyboard + monitor required)

Power on, mash **Del** to enter BIOS.

### Power Settings

<!-- Document the exact BIOS path and setting names for this model. -->

- Set **Restore on AC Power Loss** → **Power On** (or equivalent)
- Set auto-reboot on hang/freeze if available

### Boot Order

- USB first (for initial install), then internal SSD

### Photos

<!-- Drop BIOS screenshots in device-profiles/evo-x2/photos/ if you have them. -->

## OS Prep (Ubuntu live USB)

1. Boot from Ubuntu installer USB
2. Once the installer UI appears, **Ctrl+Z** to drop to shell
3. Become root: `sudo -i`
4. Enable SSH for remote provisioning:
   ```bash
   sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
   systemctl restart ssh
   passwd root    # set a temporary password
   ```
5. Get the IP: `ip a` (look for the LAN interface, usually `enp*`)

## Provisioning (from a machine with deploy keys)

From the fort-nix repo root:

```bash
just provision evo-x2 <ip-address>
```

You'll be prompted for the root password a few times during the process. This:
- Fingerprints the hardware (reads DMI product UUID)
- Generates device age keys
- Scaffolds the device flake
- Bootstraps NixOS via nixos-anywhere
- Cleans up provisioning artifacts

## Post-Provision

- Assign the device to a host: `just assign <device-uuid> <hostname>`
- First deploy: push to release branch (gitops) or use deploy-rs

## Gotchas

<!-- Add model-specific issues here as you encounter them. -->
