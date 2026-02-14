# Mac Mini Provisioning

Darwin provisioning uses `just provision mac-mini <ip>`, but requires a
one-time keyboard-and-monitor setup first to enable SSH access.

## Prerequisites (keyboard + monitor required)

1. Power on and go through macOS initial setup
2. **Create a user named `admin`** — the provisioning tooling and nix-darwin
   config expect this username. It gets passwordless sudo and the fort deploy
   key via the darwin platform builder.
3. Open **System Settings**:
   - **General → Software Update**: disable automatic updates
   - **Energy → Options**: "Start up automatically after a power failure" → **On**
   - **Displays**: display sleep → **Never** (headless)
   - **Lock Screen**: → **Never**
4. **General → Sharing → Remote Login**: toggle **On**, add admin user

## Provisioning

Once SSH is available, from the dev sandbox:

```bash
# Provision (installs CLT, Nix, nix-darwin, clones repo, captures device UUID + SSH key)
just provision mac-mini <ip>

# Assign hostname
just assign <device-uuid> <hostname>

# Re-key secrets (KEYED_FOR_DEVICES=1), commit, push to release branch
# Then SSH in for the initial build:
ssh admin@<ip>
cd /var/lib/fort-nix && sudo darwin-rebuild switch --flake ./clusters/bedlam/hosts/<hostname>
```

Agenix uses the host's SSH key (`/etc/ssh/ssh_host_ed25519_key`) as the age
identity — no separate age key file needed.

After the first `darwin-rebuild switch`, the deploy key is authorized and
passwordless sudo is enabled — subsequent deploys use `just deploy <hostname>`.

## Post-Provision

- Mesh enrollment happens automatically (launchd oneshot)
- GitOps polling starts automatically (launchd daemon, every 5 min)
- Subsequent changes deploy via `just deploy <hostname>` or git push to release
- SSH access: `just ssh <hostname>` (uses admin user automatically)
