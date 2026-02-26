# Fort Nix

A declarative NixOS homelab infrastructure with a custom inter-host control plane, GitOps deployment, and unified service exposure with SSO.

## Architecture Overview

Fort manages a cluster of NixOS hosts (and one macOS host) through layered, composable configuration. Each host's identity is built from:

- A **device profile**: Base-level image (disk layout, bootloader, hardware quirks)
    - Defined in `./device-profiles/<profile>` (beelink, evo-x2, linode, mac-mini)
- A **device entry**: Unique machine binding by hardware UUID
    - Auto-generated in `./clusters/<cluster>/devices/<uuid>`
- A **host**: Logical identity with a manifest declaring what it runs
    - Scaffolded under `./clusters/<cluster>/hosts/<name>`, primary config via `manifest.nix`
    - Composed of:
        - **Roles**: Predefined bundles of apps + aspects (e.g., `forge`, `beacon`)
        - **Apps**: Services deployed on the host (e.g., `jellyfin`, `ollama`)
        - **Aspects**: Host characteristics (e.g., `mesh`, `observable`, `egress-vpn`)

Fort supports multiple clusters simultaneously. Set the active cluster via `CLUSTER=<name>` or place the name in `.cluster`.

## Service Exposure

Services are exposed through `fort.cluster.services`, which provides centralized management of TLS, DNS, and nginx routing. Each service declaration supports:

- **visibility**: `vpn` (mesh-only), `local` (LAN + mesh), or `public` (internet-facing via beacon)
- **sso**: Optional SSO integration via Pocket ID with modes: `none`, `oidc`, `headers`, `basicauth`, `gatekeeper`, `token`
- **vpnBypass**: Skip auth for VPN requests while requiring it from the public internet

Apps declare their exposure in their module — no manual nginx configuration needed. The control plane automatically handles DNS registration (Headscale + CoreDNS), SSL certificate distribution, OIDC client registration, and public proxy setup.

## Control Plane

Fort implements a distributed control plane for inter-host coordination. Hosts expose **capabilities** (RPC endpoints via FastCGI) and declare **needs** (resources they require from other hosts).

### Key Capabilities

| Capability | Provider | Purpose |
|------------|----------|---------|
| ssl-cert | certificate-broker aspect | Wildcard cert distribution to all nginx hosts |
| oidc-register | identity provider app | Automatic OIDC client registration for SSO services |
| dns-headscale | beacon role | Mesh DNS records for all services |
| dns-coredns | forge role | LAN DNS records for all services |
| proxy | beacon role | Public ingress routing for internet-facing services |
| git-token | forge role | Deploy tokens for GitOps and dev sandbox access |
| deploy | gitops aspect | Trigger deployment on manual-confirmation hosts |
| journal, systemd, read-file | host-status aspect | Remote debugging (restricted by principal) |

### How It Works

1. Apps declare services via `fort.cluster.services` — this generates needs automatically
2. Provider hosts (forge, beacon, identity provider) aggregate needs on a timer
3. Providers fulfill needs (issue certs, register OIDC clients, add DNS records, configure proxies)
4. Consumer hosts receive responses, store state locally, and restart affected services
5. Unfulfilled needs are retried with exponential backoff (nag protocol)

The control plane is implemented in Go (`apps/*/provider/`, `aspects/*/provider/`) and served via FastCGI behind nginx with RBAC controlling which hosts can call which capabilities.

## Setting Up the Cluster

The cluster depends on two "hero" roles that need to be provisioned first:

### Beacon
The **beacon** is a coordination server for the mesh network. Public DNS points here, and it runs Headscale. A minimal VPS (e.g., Linode) is sufficient.

Once created, issue a preauthorization key:
```bash
headscale users create fort
headscale preauthkeys create --user fort --reusable --expiration 99y
# Put the value in tailscale/auth-key.age
# Redeploy both the beacon host and any other hosts to get them on-network
```

### Forge
The **forge** coordinates all other nodes. It handles:

- Internal DNS resolution via CoreDNS (with ad blocking)
- SSL certificate provisioning and distribution (ACME DNS-01 via Porkbun)
- Git hosting via Forgejo with CI/CD (Actions), mirroring to GitHub
- Nix binary cache via Attic
- Observability stack (Prometheus, Grafana, Loki)
- OCI container registry via Zot
- OIDC identity provider (Pocket ID) backed by LDAP

## CI/CD Pipeline

The forge runs Forgejo Actions workflows that automate the release process.

### Release Workflow (`release.yml`)

Runs on push to `main`:

1. **PII scan** — checks for personally identifiable patterns against an encrypted denylist
2. **Go tests** — validates all control plane provider code
3. **Flake check** — evaluates root flake, all host flakes, and all device flakes
4. **Secret re-keying** — re-keys `.age` secrets for target device host keys; tracks content SHAs to minimize unnecessary re-keying
5. **Release branch** — creates/updates the `release` branch with re-keyed secrets
6. **GitHub mirror** — pushes `main` to GitHub

### Test Branches

For risky changes, push to a `<hostname>-test` branch. CI will:

1. Validate only that host's flake
2. Re-key secrets only for that host
3. Create a `release-<hostname>-test` branch

The target host deploys with `switch-to-configuration test` — a reboot reverts to the last known-good config. Merge to `main` to finalize; delete the branch to abandon.

## Available Apps

| App | Description |
|-----|-------------|
| actualbudget | Self-hosted budgeting |
| apple-dist | Apple Developer distribution tools |
| attic | Nix binary cache |
| audiobookshelf | Audiobook and podcast server |
| calibre-web | E-book management web interface |
| comfyui | Stable Diffusion workflow UI |
| conduit | Matrix homeserver |
| coredns | Internal DNS with ad blocking |
| flatnotes | Markdown note-taking |
| forgejo | Git hosting with CI/CD and GitHub mirroring |
| fort-mcp | Model Context Protocol server |
| fort-observability | Prometheus, Grafana, Loki stack |
| fort-tokens | Bearer token management web UI |
| frigate | NVR with AI object detection |
| gatus | Health monitoring and status page |
| headscale | Self-hosted Tailscale control server |
| homeassistant | Home automation platform |
| homepage | Customizable dashboard |
| hugo-blog | Static site generator |
| jellyfin | Media streaming server |
| lidarr | Music collection manager |
| ollama | Local LLM inference (Vulkan backend) |
| open-webui | Web interface for Ollama |
| outline | Team knowledge base (OIDC SSO) |
| pocket-id | OIDC identity provider backed by LDAP |
| prowlarr | Indexer manager for *arr stack |
| qbittorrent | BitTorrent client (egress VPN) |
| radarr | Movie collection manager |
| radicale | CalDAV/CardDAV server |
| readarr | Book collection manager |
| sillytavern | LLM chat frontend |
| silverbullet | Markdown-based personal knowledge management |
| sonarr | TV show collection manager |
| super-productivity | Task and time management |
| termix | Terminal-based collaboration tool |
| tts | Text-to-speech (Kokoro) |
| upload-gateway | Web UI for uploading files to hosts |
| vdirsyncer-auth | OAuth adapter for calendar sync |
| vikunja | Task and project management |
| whisper | Speech-to-text transcription |
| zot | OCI container registry |

## Available Aspects

| Aspect | Description |
|--------|-------------|
| certificate-broker | ACME wildcard cert provisioning and distribution |
| deployer | deploy-rs SSH key generation for remote deploys |
| dev-sandbox | Development environment with AI tooling and secret access |
| egress-vpn | WireGuard namespace routing through external VPN |
| gitops | Automatic deployment from release branch via comin |
| host-status | Control plane endpoint for host health queries |
| ldap | LLDAP directory service with bootstrapped users/groups |
| media-kiosk | Kiosk mode display |
| mesh | Tailscale VPN mesh membership |
| mosquitto | MQTT broker for IoT devices |
| observable | Prometheus node exporter for metrics scraping |
| public-ingress | Public-facing nginx reverse proxy (beacon) |
| wifi-access | WiFi network configuration |
| zfs | ZFS filesystem support with optional pools |
| zigbee2mqtt | Zigbee device gateway with declarative device naming |
| zwave-js-ui | Z-Wave device gateway with declarative device naming |

## Setting Up a New Host

### Provisioning

Boot the target device into any environment with SSH root access (e.g., Ubuntu Server LiveISO), then:

```bash
just provision <device-type> <ip>
# e.g. just provision beelink 192.168.1.42
```

This fingerprints the device by hardware UUID, writes a device flake under `./clusters/<cluster>/devices/<uuid>`, and converts the machine to NixOS via nixos-anywhere.

### Assigning

```bash
just assign <device-uuid> <hostname>
# e.g. just assign f848d467-b339-4b5d-a8a0-de1ea07ba304 marmaduke
```

This creates the host flake at `./clusters/<cluster>/hosts/<hostname>`. Edit `manifest.nix` to declare apps, aspects, and roles, then deploy.

### Deploying

#### GitOps (Default)

Push to `main` and wait. CI validates, re-keys secrets, and pushes to `release`. Hosts with the `gitops` aspect pull and deploy automatically (~5 minutes).

Hero roles (beacon, forge) use manual confirmation — they build automatically but won't switch until explicitly triggered. Other hosts sensitive to unscheduled restarts can also opt into manual confirmation via their gitops aspect config.

```bash
just deploy <host>    # Blocks until deployed; triggers manual confirmation if needed
```

#### Initial Deploy

```bash
just deploy <hostname> <ip>
# e.g. just deploy marmaduke 192.168.1.42
```

When the IP is omitted, Fort targets `<hostname>.fort.<domain>` over the mesh.

## Access Control

Access is managed through **principals** defined in the cluster manifest. Each principal has a public key and roles:

| Role | Grants |
|------|--------|
| `root` | SSH as root to all hosts |
| `dev-sandbox` | SSH as dev user on dev-sandbox hosts |
| `secrets` | Can decrypt secrets (age key in agenix recipients) |

Secrets use **agenix**. On `main`, secrets are keyed for principals with the `secrets` role (dev/testing). CI re-keys them for target device host keys on the `release` branch.

## Commands

| Command | Description |
|---------|-------------|
| `just test [host]` | Flake check (single host or all hosts/devices) |
| `just deploy <host> [ip]` | Deploy a host (auto-detects method) |
| `just provision <profile> <ip>` | Provision a new device |
| `just assign <uuid> <name>` | Create a host from a provisioned device |
| `just fmt` | Format all Nix files |
| `just ssh <host>` | SSH into a host using the deploy key |
| `just age <path>` | Edit an age-encrypted secret |

## IoT and Home Automation

Fort supports declarative Home Assistant configuration with:

- **Zigbee2MQTT**: Zigbee device gateway with declarative device naming
- **Z-Wave JS UI**: Z-Wave device gateway with declarative device naming
- **Mosquitto**: MQTT broker for device communication
- **Frigate**: NVR with AI-powered object detection
- **Home Assistant**: Automations, scenes, scripts, and dashboards defined in Nix

IoT device manifests are encrypted and support both Zigbee (IEEE address) and Z-Wave (DSK) devices:

```
# Zigbee devices
0x00158d00xxxxxxxx:script_name:Friendly Name

# Z-Wave devices
00000-00000-00000-00000-00000-00000-00000-00000:script_name:FriendlyName
```

