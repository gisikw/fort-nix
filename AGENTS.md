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
  manifest.nix               # Cluster settings (domain, SSH keys)
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
2. Declare exposure via `fortCluster.exposedServices`:

```nix
fortCluster.exposedServices = [{
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

### SSO Modes

| Mode | Use When |
|------|----------|
| `none` | Service handles its own auth, or no auth needed |
| `oidc` | Service supports OIDC natively (credentials delivered to `/var/lib/fort-auth/<svc>/`) |
| `headers` | Service can consume `X-Auth-*` headers from oauth2-proxy |
| `basicauth` | Service only supports HTTP Basic Auth (proxy translates) |
| `gatekeeper` | Login required but no identity passed to backend |

#### OIDC Credential Delivery

When using `sso.mode = "oidc"`, the `service-registry` aspect (running on the forge host) automatically:

1. Registers an OIDC client in pocket-id using the service's FQDN as the client name
2. SSHs credentials to the target host at `/var/lib/fort-auth/<service-name>/`:
   - `client-id` - the OIDC client ID
   - `client-secret` - the OIDC client secret
3. Restarts the service specified in `sso.restart` (defaults to `oauth2-proxy-<name>`)

**App responsibilities** when using `oidc` mode:

```nix
# 1. Declare the exposure with restart target
fortCluster.exposedServices = [{
  name = "myapp";
  port = 8080;
  sso = {
    mode = "oidc";
    restart = "myapp.service";  # Service to restart after creds delivered
  };
}];

# 2. Create tmpfiles for credential directory
systemd.tmpfiles.rules = [
  "d /var/lib/fort-auth/myapp 0700 myapp myapp -"
];

# 3. Configure the app to read credentials and use pocket-id endpoints:
#    - Issuer/Auth URL: https://id.${domain}/authorize
#    - Token URL: https://id.${domain}/api/oidc/token
#    - Userinfo URL: https://id.${domain}/api/oidc/userinfo
```

See `apps/outline/default.nix` for a complete example using `wrapProgram` to inject credentials at runtime.

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
fortCluster.exposedServices = [{
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
just test                    # Flake check on all hosts/devices
```

### GitOps Hosts (Most Hosts)

For hosts with the `gitops` aspect, deployment is automatic:

1. Commit and push to `main`
2. CI validates and updates `release` branch
3. Hosts auto-pull and deploy (~5 min total)

**Do NOT run `just deploy` for these hosts** - just commit and push.

**GitOps hosts**: joker, lordhenry, minos, q, ratched, ursula

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

### Non-GitOps Hosts (Forge/Beacon)

The forge (drhorrible) and beacon (raishan) require manual deployment. After committing and pushing, **ask the user** to deploy:

```
User, please deploy drhorrible: `just deploy drhorrible`
```

Agents cannot run `just deploy` directly - it requires SSH access that agents don't have.

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

## Impermanence

Some hosts (beelink, evo-x2) use tmpfs root with `/persist/system` for state. Services needing persistent data should use `/var/lib` (which is persisted).

## What to Avoid

- Don't modify `flake.nix` or `common/` without good reason
- Don't hardcode IPs or hostnames - use `${domain}` from cluster manifest
- Don't add nginx virtual hosts manually - use `fortCluster.exposedServices`
- Don't commit unencrypted secrets

## Working on Tickets

- Include the ticket ID in commit messages (e.g., `fort-cy6.9: Add attic binary cache`)
- For extended debugging sessions (3+ iterations without clear progress), pause and consider:
  - Is this the right approach, or am I in a rabbit hole?
  - Should we ticket remaining work and get a clean deploy first?
  - Ask the user for a gut check
- When adding debug logging, **leave it in place until the issue is confirmed fixed**. Removing debug lines prematurely just leads to re-adding them when the next issue appears.

## Completing Work

Before closing a ticket:

1. **Stage and test**: `git add <files>` then `just test` - Nix requires files to be staged.

2. **Commit and push**: This triggers GitOps for most hosts.

3. **Request manual deploy if needed**: If the change affects drhorrible (forge) or raishan (beacon), ask the user to deploy those hosts manually.

4. **Close the ticket**: `bd close <id>`

5. **Reflect** and triage with the user:
   - **Documentation**: Did this work reveal anything that should be in AGENTS.md or README.md? New patterns, gotchas, or corrections to existing guidance?
   - **Process friction**: What slowed things down? Missing tools, unclear docs, manual steps that could be automated?
   - **Pattern extraction**: Did the code changes reveal a pattern worth generalizing? A new SSO mode, a reusable derivation structure, a common module shape?
   - **Discovered work**: Did you uncover related issues while working?

   For each item surfaced: **ticket it, document it, address it now, or explicitly discard it**. Don't just note friction and move on - that's venting, not improving. Quick triage with the user ensures nothing gets lost.

6. **Commit doc updates** if reflection produced any:
   ```bash
   git add <files>
   git commit -m "<beads-id>: <summary>"
   git push
   ```

This isn't ceremony for its own sake - it's how the codebase and tooling improve over time.
