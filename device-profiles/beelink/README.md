# Beelink Provisioning

## BIOS Setup (keyboard + monitor required)

Power on, mash **Del** (or **F7** on some models) to enter BIOS.

### Power Settings

> These vary by BIOS revision. Some Beelink models are cursed — the "restore
> on AC power loss" option may be missing or broken. Document what you find for
> this specific unit.

- **State after G3**: set to **S0** (power on after AC loss)
- **Wake system from S5**: set to **Dynamic**, 1 min (some models use "AC Power
  Recovery" or "Restore on AC Power Loss" → **Power On**)
- If neither of these exist, check Advanced → Power Management. Some units
  default to suspend-on-power-restore which is miserable — you need "Last
  State" or "Power On", not "S5" or "Suspend"

### Boot Order

- USB first (for initial install), then internal SSD

### Photos

<!-- Drop BIOS screenshots in device-profiles/beelink/photos/ if you have them.
     The BIOS layout changes between models and it's impossible to remember. -->

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
just provision beelink <ip-address>
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

- **The suspend-on-power-restore BIOS bug**: At least one Beelink unit had a
  BIOS that defaulted to suspend (not power on) after AC loss, with no obvious
  setting to change it. Required digging through every BIOS submenu. If you hit
  this, document which model and what worked.
- The Ubuntu installer USB needs to be the standard desktop installer (server
  installer doesn't drop to shell the same way with Ctrl+Z)
