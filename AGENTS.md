# Agent Instructions

This is a NixOS homelab infrastructure. Read `README.md` for architecture overview.

**Note**: `CLAUDE.md` is a symlink to this file. Edit `AGENTS.md` directly.

**Maintenance note**: When making changes to core infrastructure patterns (common/, new SSO modes, new aspect types, etc.), review this file and update it if the guidance has changed.

## Issue Tracking

This project uses **bd** (beads) for issue tracking. Prefer bd over TodoWrite - use TodoWrite only for complex single-session work where micro-step tracking adds clarity.

```bash
bd ready                              # Find available work
bd show <id>                          # View issue details
bd update <id> --status in_progress   # Claim work
bd close <id>                         # Complete work
```

## Codebase Navigation

```
flake.nix                    # Root flake (minimal, forwards to common/)
common/
  host.nix                   # Host flake boilerplate - module loading logic
  device.nix                 # Device flake boilerplate
  fort.nix                   # Service exposure, nginx, oauth2-proxy (~240 lines, important)
  cluster-context.nix        # Entry point for locating manifests
clusters/<cluster>/
  manifest.nix               # Cluster settings (domain, principals)
  hosts/<name>/manifest.nix  # Host config: roles, apps, aspects
  devices/<uuid>/            # Auto-generated device bindings
pkgs/<name>/default.nix      # Custom derivations for external projects
apps/<name>/default.nix      # App modules
aspects/<name>/default.nix   # Aspect modules
roles/<name>.nix             # Role definitions (sets of apps + aspects)
device-profiles/<type>/      # Hardware base images (beelink, linode, etc.)
```

## Key Patterns

### Adding an App

Apps live in `apps/<name>/default.nix`. Every app should:

1. Define its systemd service(s)
2. Declare exposure via `fort.cluster.services`:

```nix
fort.cluster.services = [{
  name = "myapp";
  port = 8080;
  visibility = "local";      # vpn | local | public
  sso = {
    mode = "none";           # none | oidc | headers | basicauth | gatekeeper
    groups = [ "users" ];    # LDAP groups (if SSO enabled)
  };
}];
```

Then add it to a host's `manifest.nix`:
```nix
{ apps = [ "myapp" ]; ... }
```

After deploying a new app with a subdomain, refresh the service registry so DNS picks it up immediately:

```bash
just deploy <host>                                           # Wait for host deploy
fort-agent-call drhorrible restart '{"unit": "fort-service-registry"}'  # Refresh DNS
```

Use restart **without** delay unless the service would kill the response (nginx, fort-agent, tailscale).

### SSO Modes

Services can use SSO via `fort.cluster.services`:

| Mode | Use When |
|------|----------|
| `none` | Service handles its own auth, or no auth needed |
| `oidc` | Service supports OIDC natively |
| `headers` | Service can consume `X-Auth-*` headers |
| `basicauth` | Service only supports HTTP Basic Auth |
| `gatekeeper` | Login required but no identity passed to backend |

For detailed implementation guidance, mode-specific patterns, and troubleshooting, see the `sso-guide` skill (`.claude/skills/sso-guide/`). Working examples: `apps/outline/` (oidc), `apps/fort-observability/` (headers).

### Custom Derivations

For external projects that are too fast-moving for nixpkgs (or not in nixpkgs), create a derivation in `pkgs/<name>/default.nix`:

```nix
# pkgs/myapp/default.nix
{ pkgs }:

pkgs.stdenv.mkDerivation {
  pname = "myapp";
  version = "1.2.3";
  src = pkgs.fetchurl {
    url = "https://github.com/.../releases/download/v1.2.3/myapp-linux-amd64";
    sha256 = "sha256-...";
  };
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.autoPatchelfHook ];
  installPhase = ''install -Dm755 $src $out/bin/myapp'';
}
```

Then import it in the app module:
```nix
# apps/myapp/default.nix
let
  myapp = import ../../pkgs/myapp { inherit pkgs; };
in { ... }
```

See `pkgs/zot/` for a working example.

**What goes in `pkgs/`**: External projects we're packaging ourselves.

**What stays in `apps/`**: Context-dependent wraps (secret injection, config overrides) that are specific to how we deploy the service. See `apps/outline/` for an example using `symlinkJoin` + `wrapProgram`.

**Self-contained services**: For fast-moving packages where the nixpkgs module may lag or have compatibility issues, define the systemd service directly in `apps/` rather than using `services.<name>`. See `apps/pocket-id/` - it defines users, tmpfiles, and systemd services inline rather than relying on nixpkgs' `services.pocket-id` module.

### Service Initialization

**Prefer declarative configuration** when the service supports it. Many services allow pre-configuring users, tokens, databases, etc. through their NixOS module options - use these whenever available.

When imperative setup is unavoidable, use one of these patterns:

**Bootstrap services** for one-time setup (tokens, initial resources):

```nix
systemd.services.myapp-bootstrap = {
  after = [ "myapp.service" ];
  requires = [ "myapp.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;  # Don't re-run on restart
  };
  script = ''
    # Idempotent - check before creating
    if [ ! -s "$TOKEN_FILE" ]; then
      myapp-admin create-token > "$TOKEN_FILE"
    fi
  '';
};
```

See `apps/forgejo/default.nix` (org/repo/mirror setup) and `apps/attic/default.nix` (cache/token creation).

**Reconciliation services** for continuous true-up when state must match config:

```nix
systemd.timers.myapp-sync = {
  wantedBy = [ "timers.target" ];
  timerConfig.OnUnitActiveSec = "10m";
};
systemd.services.myapp-sync = {
  serviceConfig.Type = "oneshot";
  script = ''
    # Sync declared state to runtime state
    for client in $DECLARED_CLIENTS; do
      ensure_client_exists "$client"
    done
  '';
};
```

See `aspects/service-registry/` (OIDC client sync with pocket-id) and `apps/pocket-id/default.nix` (service key rotation).

Key principles for both patterns:
- **Idempotent**: Check before creating, handle already-exists gracefully
- **Persistent state**: Store tokens/markers in `/var/lib/<app>/`
- **Ordered**: Use `after`/`requires` for dependencies

### Parameterized Aspects

Aspects can receive arguments when declared in a host manifest:

```nix
# Simple (no args)
aspects = [ "mesh" "observable" ];

# With parameters
aspects = [
  { name = "zigbee2mqtt"; passwordFile = ./mqtt-password.age; }
];
```

### Egress VPN Namespace

Services that should route through the external VPN (e.g., torrent clients):

```nix
fort.cluster.services = [{
  name = "qbittorrent";
  port = 8080;
  inEgressNamespace = true;  # Routes through WireGuard namespace
  ...
}];
```

The host must have the `egress-vpn` aspect enabled.

### Forge Configuration

The cluster manifest can declare forge-specific settings for the git infrastructure:

```nix
# clusters/<cluster>/manifest.nix
fortConfig = {
  settings = { ... };

  forge = {
    org = "infra";           # Forgejo organization name
    repo = "fort-nix";       # Repository name
    mirrors = {
      github = {
        remote = "github.com/user/repo";
        tokenFile = ./github-mirror-token.age;  # PAT for push access
      };
    };
  };
};
```

The `forgejo` app reads this config and runs a bootstrap service on activation that:
1. Creates a `forge-admin` service account with API token
2. Creates the org and repo if they don't exist
3. Configures push mirrors to sync to external remotes (e.g., GitHub)

Mirror tokens should be added to `secrets.nix` with the appropriate public keys.

### Dev Sandbox Forge Access

Hosts with the `dev-sandbox` aspect get automatic Forgejo access:

**Declarative (in aspect):**
- Git credential helper at `/etc/fort-git-credential-helper`
- Git config pointing to the helper for `https://git.<domain>`

**Runtime (distributed by forge):**
- `forgejo-deploy-token-sync` checks each host's `/var/lib/fort/host-manifest.json`
- Hosts with `dev-sandbox` aspect receive a read/write token at `/var/lib/fort-git/forge-token`
- Other hosts receive read-only tokens
- Sync runs on a 10-minute timer

After deployment, git push just works - no manual credential setup:

```bash
git clone https://git.<domain>/infra/fort-nix.git
git push  # Credential helper reads token automatically
```

If rebuilding the dev-sandbox environment, wait for the next token sync (~10 min) or manually trigger it on the forge host: `systemctl start forgejo-deploy-token-sync`

## Access Control (Principals)

Access is managed through **principals** defined in `clusters/<cluster>/manifest.nix`. Each principal has a public key and roles determining what they can access:

```nix
principals = {
  admin = {
    description = "Admin user - full access";
    publicKey = "ssh-ed25519 AAAA... fort";
    privateKeyPath = "~/.ssh/fort";  # Only for principals that run deploy-rs
    roles = [ "root" "dev-sandbox" "secrets" ];
  };
  forge = {
    description = "Forge host (drhorrible) - credential distribution";
    publicKey = "ssh-ed25519 AAAA... fort-deployer";
    roles = [ "root" ];
  };
  ratched = {
    description = "Dev sandbox / LLM agents";
    publicKey = "age1...";  # age keys work for secrets, not SSH
    roles = [ "secrets" ];
  };
  ci = {
    description = "Forgejo CI";
    publicKey = "age1...";
    roles = [ "secrets" ];
  };
};
```

**Roles:**
| Role | Grants |
|------|--------|
| `root` | SSH as root to all hosts (key added to root's authorized_keys) |
| `dev-sandbox` | SSH as dev user on hosts with dev-sandbox aspect |
| `secrets` | Can decrypt secrets on main branch (key included in agenix recipients) |

**Key types:**
- SSH keys (`ssh-ed25519 ...`) work for both SSH access and secret decryption
- Age keys (`age1...`) work only for secret decryption

The consuming code (`host.nix`, `secrets.nix`, `dev-sandbox`) derives the appropriate key lists from principals based on their roles.

## Secrets

Uses **agenix**. Secrets are `.age` files decrypted at activation time.

Declare secrets in `secrets.nix`. Use in modules:
```nix
age.secrets.my-secret.file = ./my-secret.age;
# Access via: config.age.secrets.my-secret.path
```

### Dev Sandbox Decryption

The dev sandbox has an age key at `~/.config/age/keys.txt` that can decrypt secrets on `main` (but not `release`). To test decryption:

```bash
nix-shell -p age --run "age -d -i ~/.config/age/keys.txt <secret.age>"
```

## Testing & Deployment

```bash
# For single-host changes (faster)
nix flake check ./clusters/bedlam/hosts/<host>

# For multi-host or common/ changes
just test                    # Flake check on all hosts/devices
```

### GitOps Hosts (Most Hosts)

For hosts with the `gitops` aspect:

1. Commit and push to `main`
2. Run `just deploy <host>` to wait for deployment

The command auto-detects the right method and blocks until the host is running your commit:
- **With master key**: deploy-rs direct push
- **Without master key**: Polls GitOps status, triggers deploy if needed, waits for activation

**Auto-deploy hosts**: joker, lordhenry, minos, q, ratched, ursula

**Manual-confirmation hosts**: drhorrible, raishan (build automatically, but `just deploy` triggers the switch)

### Testing Changes Safely (Test Branches)

For risky changes, use test branches to deploy without modifying the bootloader (recoverable via reboot):

```bash
git checkout -b <hostname>-test
# make changes
git push origin <hostname>-test
```

CI will:
1. Validate only that host's flake
2. Re-key secrets only for that host
3. Create `release-<hostname>-test` branch

Comin on the target host picks up the testing branch and deploys with `switch-to-configuration test`. If broken, reboot reverts to the last booted config.

**To finalize**: Merge your changes to `main`. Once the `release` branch updates, comin automatically switches back from the testing branch.

**To abandon**: Delete the `<hostname>-test` branch. Comin will revert to `release` on next poll.

### Manual-Confirmation Hosts (Forge/Beacon)

The forge (drhorrible) and beacon (raishan) use GitOps but with **manual confirmation** - they pull and build automatically, but won't switch until explicitly triggered. This prevents surprise deploys on critical infrastructure.

Use `just deploy <host>` like any other host - it handles the confirmation automatically. If the agent API isn't responding, ask the user to run the command instead.

## Debugging Deployment Failures

**Important**: deploy-rs automatically rolls back on activation failure. If a deploy fails, the host reverts to its previous state - checking service status afterward won't reflect your changes.

Agents cannot use interactive SSH. For remote diagnostics, get the SSH key path and domain from the cluster manifest (`clusters/<cluster>/manifest.nix`), then construct one-shot commands:

```bash
ssh -i <key_path> root@<host>.fort.<domain> "journalctl -xe --no-pager | tail -100"
ssh -i <key_path> root@<host>.fort.<domain> "systemctl --failed"
ssh -i <key_path> root@<host>.fort.<domain> "journalctl -u <service> -n 50 --no-pager"
```

Common issues:
- **Secret not decrypted**: Check `age.secrets` declaration and `secrets.nix`
- **Port conflict**: Another service on the same port
- **Missing state directory**: Check `systemd.tmpfiles.rules` or `StateDirectory`

## Inter-Host Agent Calls

Agents in the dev-sandbox can query and control other hosts using `fort-agent-call`. This enables debugging, deployment, and cluster management without SSH access.

```bash
# Check a host's status (uptime, failed units, deploy info)
fort-agent-call drhorrible status '{}'

# Get a host's manifest (apps, aspects, roles, exposed services)
fort-agent-call joker manifest '{}'

# List GC handles held by a host
fort-agent-call ursula holdings '{}'
```

**Output format**: JSON envelope with `body`, `status`, `handle`, `ttl` fields.

**Available on all hosts**: `status`, `manifest`, `holdings`

### Debug Capabilities

These capabilities are restricted to the `dev-sandbox` principal for operational safety:

```bash
# Trigger deployment on manual-confirmation hosts (forge/beacon)
fort-agent-call drhorrible deploy '{"sha": "5563ac2"}'

# Fetch journal logs for a service
fort-agent-call joker journal '{"unit": "nginx", "lines": 50}'
fort-agent-call joker journal '{"unit": "fort-agent", "since": "5 min ago"}'

# Restart a service (immediate - preferred, fails if restart fails)
fort-agent-call joker restart '{"unit": "fort-service-registry"}'

# Restart with delay (only for nginx/fort-agent/tailscale - avoids killing response)
fort-agent-call joker restart '{"unit": "nginx", "delay": 2}'
```

| Capability | Request | Notes |
|------------|---------|-------|
| `deploy` | `{sha}` | Only on gitops hosts; verifies SHA before confirming |
| `journal` | `{unit, lines?, since?}` | Returns journalctl output |
| `restart` | `{unit, delay?}` | Restarts systemd unit; use delay only for nginx/fort-agent/tailscale |

**Custom capabilities**: Some hosts expose additional endpoints (e.g., `oidc-register` on the identity provider). The RBAC system determines which hosts can call which capabilities based on cluster topology.

For detailed guidance on adding capabilities, writing handlers, and the GC protocol, see the `agent-api-guide` skill.

## Impermanence

Some hosts (beelink, evo-x2) use tmpfs root with `/persist/system` for state. Services needing persistent data should use `/var/lib` (which is persisted).

## What to Avoid

- Don't modify `flake.nix` or `common/` without good reason
- Don't hardcode IPs or hostnames - use `${domain}` from cluster manifest
- Don't add nginx virtual hosts manually - use `fort.cluster.services`
- Don't commit unencrypted secrets
- Don't use `:latest` container tags - pin to explicit versions (e.g., `:1.10.0`) for reproducible deploys
- Don't use Write tool for large file transformations - prefer `mv` to rename then Edit for in-place changes (more token-efficient and avoids tool call overhead)

## Working on Tickets

- Include the ticket ID in commit messages (e.g., `fort-cy6.9: Add attic binary cache`)
- For extended debugging sessions (3+ iterations without clear progress), pause and consider:
  - Is this the right approach, or am I in a rabbit hole?
  - Should we ticket remaining work and get a clean deploy first?
  - Ask the user for a gut check
- When adding debug logging, **leave it in place until the issue is confirmed fixed**. Removing debug lines prematurely just leads to re-adding them when the next issue appears.

## Completing Work

Before closing a ticket:

1. **Stage and test**: `git add <files>` then `nix flake check ./clusters/bedlam/hosts/<host>` (or `just test` for multi-host changes) - Nix requires files to be staged.

2. **Commit and push**: This triggers GitOps for most hosts.

3. **Wait for deploy**: Run `just deploy <host>` even for auto-deploy hosts. This ensures the deploy completes before closing the ticket.

4. **Close the ticket**: `bd close <id>`

5. **Reflect** and triage with the user:
   - **Documentation**: Did this work reveal anything that should be in AGENTS.md or README.md? New patterns, gotchas, or corrections to existing guidance?
   - **Process friction**: What slowed things down? Missing tools, unclear docs, manual steps that could be automated?
   - **Pattern extraction**: Did the code changes reveal a pattern worth generalizing? A new SSO mode, a reusable derivation structure, a common module shape?
   - **Skill candidates**: Did you repeatedly reference a specific AGENTS.md section, or wish you had step-by-step guidance for a workflow? Consider whether it should be a skill (loaded on-demand) rather than always-present context.
   - **Discovered work**: Did you uncover related issues while working?

   For each item surfaced: **ticket it, document it, address it now, or explicitly discard it**. Don't just note friction and move on - that's venting, not improving. Quick triage with the user ensures nothing gets lost.

6. **Commit doc updates** if reflection produced any:
   ```bash
   git add <files>
   git commit -m "<beads-id>: <summary>"
   git push
   ```

This isn't ceremony for its own sake - it's how the codebase and tooling improve over time.
