# Agent Instructions

This is a NixOS homelab infrastructure. Read `README.md` for architecture overview.

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

## Secrets

Uses **agenix**. Secrets are `.age` files decrypted at activation time.

Declare secrets in `secrets.nix`. Use in modules:
```nix
age.secrets.my-secret.file = ./my-secret.age;
# Access via: config.age.secrets.my-secret.path
```

## Testing & Deployment

```bash
just test                    # Flake check on all hosts/devices
just deploy <host> [ip]      # Deploy (IP needed for first deploy)
```

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

## Completing Work

Before closing a ticket:

1. **Stage files**: `git add <files>` - Nix requires files to be staged to see them in the flake.

2. **Validate**: Deploy to all hosts impacted by the change (`just deploy <host>`). The user will intervene if unsafe.

3. **Close the ticket**: `bd close <id>`

4. **Reflect** and triage with the user:
   - **Documentation**: Did this work reveal anything that should be in AGENTS.md or README.md? New patterns, gotchas, or corrections to existing guidance?
   - **Process friction**: What slowed things down? Missing tools, unclear docs, manual steps that could be automated?
   - **Pattern extraction**: Did the code changes reveal a pattern worth generalizing? A new SSO mode, a reusable derivation structure, a common module shape?
   - **Discovered work**: Did you uncover related issues while working?

   For each item surfaced: **ticket it, document it, address it now, or explicitly discard it**. Don't just note friction and move on - that's venting, not improving. Quick triage with the user ensures nothing gets lost.

5. **Commit immediately** after reflection (so doc updates are included):
   ```bash
   git add <files>
   git commit -m "<beads-id>: <summary>"
   ```

This isn't ceremony for its own sake - it's how the codebase and tooling improve over time.
