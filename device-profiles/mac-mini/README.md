# Mac Mini Provisioning

Darwin hosts can't be provisioned via `just provision` — there's no
nixos-anywhere equivalent. This is a ~10 minute keyboard-and-monitor procedure.

## Initial macOS Setup (keyboard + monitor required)

1. Power on and go through macOS initial setup
2. Create an admin user (this is the user nix-darwin will manage)
3. Once at the desktop, open **System Settings**

### System Settings

- **General → Software Update**: disable automatic updates (nix-darwin manages this)
- **Energy → Options**: set "Start up automatically after a power failure" → **On**
- **Displays**: set display sleep to **Never** (headless)
- **Lock Screen**: set to **Never**

### Enable Remote Login

- **General → Sharing → Remote Login**: toggle **On**
- Add your admin user to the allowed users list

### Photos

<!-- Drop setup screenshots in device-profiles/mac-mini/photos/ if helpful. -->

## Install Nix

From another machine, SSH in:

```bash
ssh <admin-user>@<ip-address>
```

Then install Nix (multi-user):

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

Close and reopen the shell (or `source /etc/bashrc`) to pick up the nix PATH.

## Install nix-darwin

```bash
# Bootstrap nix-darwin
nix run nix-darwin -- switch --flake github:LnL7/nix-darwin#simple
```

This gives you the `darwin-rebuild` command.

## Clone and Build

```bash
sudo mkdir -p /var/lib/fort
sudo git clone --branch release https://git.gisi.network/infra/fort-nix.git /var/lib/fort-nix

# Set up the age key for agenix secrets
# (copy from secure storage or generate + re-key)
sudo install -m 0400 /path/to/age-key.txt /var/lib/fort/age-key.txt

# Initial build
cd /var/lib/fort-nix
darwin-rebuild switch --flake ./clusters/bedlam/hosts/<hostname>
```

## Device + Host Setup

Unlike physical NixOS hosts, darwin devices don't use `just provision`. You
need to manually create the device and host entries:

1. **Create device entry**: `clusters/bedlam/devices/<uuid>/manifest.nix`
   - Use a generated UUID (`uuidgen` on macOS)
   - Set `profile = "mac-mini"`
   - Add the host's SSH public key as `pubkey`

2. **Create host manifest**: `clusters/bedlam/hosts/<hostname>/manifest.nix`
   - Reference the device UUID
   - Add desired aspects (at minimum: `"mesh"`, `"gitops"`)

3. **Create host flake**: `clusters/bedlam/hosts/<hostname>/flake.nix`
   - Copy from an existing host — they're all identical

4. **Re-key agenix secrets** to include the new host's age key, then push to
   release branch

## Post-Provision

After the initial `darwin-rebuild switch`:
- Mesh enrollment happens automatically (launchd oneshot)
- GitOps polling starts automatically (launchd daemon, every 5 min)
- Subsequent changes deploy via git push to release branch

## Gotchas

- **No `just provision`**: darwin hosts are manual setup. The `just` recipes
  assume nixos-anywhere which doesn't support macOS.
- **Age key**: must be placed at `/var/lib/fort/age-key.txt` before the first
  rebuild that uses agenix secrets.
- **Xcode CLI tools**: if this host will be a Forgejo runner for iOS builds,
  install Xcode CLI tools separately: `xcode-select --install`
