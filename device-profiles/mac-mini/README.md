# Mac Mini Provisioning

Darwin provisioning uses `just provision mac-mini <ip> <user>`, but requires a
one-time keyboard-and-monitor setup first to enable SSH access.

## Prerequisites (keyboard + monitor required)

1. Power on and go through macOS initial setup
2. Create an admin user (this is the user nix-darwin will manage)
3. Open **System Settings**:
   - **General → Software Update**: disable automatic updates
   - **Energy → Options**: "Start up automatically after a power failure" → **On**
   - **Displays**: display sleep → **Never** (headless)
   - **Lock Screen**: → **Never**
4. **General → Sharing → Remote Login**: toggle **On**, add admin user

## Provisioning

Once SSH is available, from the dev sandbox:

```bash
# Provision (installs Nix, nix-darwin, clones repo, captures device UUID + SSH key)
just provision mac-mini <ip> <admin-user>

# Assign hostname
just assign <device-uuid> <hostname>

# Copy age key for secret decryption
scp age-key.txt <admin-user>@<ip>:/var/lib/fort/age-key.txt

# Re-key secrets, commit, push to release branch
# Then SSH in for the initial build:
ssh <admin-user>@<ip>
cd /var/lib/fort-nix && darwin-rebuild switch --flake ./clusters/bedlam/hosts/<hostname>
```

## Post-Provision

- Mesh enrollment happens automatically (launchd oneshot)
- GitOps polling starts automatically (launchd daemon, every 5 min)
- Subsequent changes deploy via git push to release branch

## Gotchas

- **Age key**: must be at `/var/lib/fort/age-key.txt` before the first rebuild
  that uses agenix secrets.
- **Xcode CLI tools**: if this host will be a Forgejo runner for iOS builds,
  install separately: `xcode-select --install`
