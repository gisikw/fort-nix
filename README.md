# Fort Nix

A declarative Nix-based homelab configuration using nixos-anywhere and deploy-rs.

## Layered Host Configuration

Fort supports multiple clusters simultaneously. Set the active cluster by
exporting `CLUSTER=<name>` before running any `just` commands, or place the
desired name in `.cluster` (copy `.cluster.example` to get started). All host
and device flakes live under `./clusters/<cluster>/`, and the helper module
`common/cluster-context.nix` is the single entry point for locating manifests,
hosts, and devices on disk.

Each host still has its own `flake.nix` and `flake.lock` files for quick
evaluation, but those files remain intentionally sparse. Shared host/device
logic lives in `./common/host.nix` and `./common/device.nix`, while app,
aspect, and role definitions remain under `./apps`, `./aspects`, and `./roles`.

The configuration for a host is composed of several layers:

- A **device profile**: Base-level image configuration (e.g., disk layout, bootloader)
    - Defined in `./device-profiles/<profile>` (beelink, evo-x2, linode)
- A **device entry**: Unique machine binding by UUID
    - Auto-generated in `./clusters/<cluster>/devices/<uuid>`
- A **host**: Logical identity, tied to a device UUID
    - Scaffolded under `./clusters/<cluster>/hosts/<name>`, with primary configuration via `manifest.nix`
    - Composed of:
        - **Aspects**: characteristics of the given host (e.g., `wifi-access`, `observable`, `mesh`)
        - **Apps**: apps that are deployed on the host (e.g., `jellyfin`, `home-assistant`)
        - **Roles**: predefined sets of aspects and apps

## Service Exposure

Services are exposed through `fortCluster.exposedServices`, which provides centralized management of TLS, DNS, and nginx routing. Each service declaration supports:

- **visibility**: `vpn` (mesh-only), `local` (LAN + mesh), or `public` (internet-facing via beacon)
- **sso**: Optional SSO integration via Pocket ID with modes including `oidc`, `headers`, `basicauth`, and `gatekeeper`

Apps should declare their exposure in their module rather than requiring manual nginx configuration.

## Setting Up the Cluster

The cluster depends on two "hero" roles that need to be provisioned before any others:

### Beacon
The **beacon** is a host that exists as a coordination server for the mesh
network. This is the box to which public DNS is pointed, and it runs Headscale.
While you _could_ run this device on your home network, that would risk
exposing your residential IP address. A minimal VPS (e.g., Linode) is
sufficient for handling this workload.

Once the beacon is created, you'll want to issue a preauthorization key so that
additional nodes can be added to the mesh network:

```bash
headscale users create fort
headscale preauthkeys create --user fort --reusable --expiration 99y
# Put the value in tailscale/auth-key.age
# Redeploy both the beacon host and any other hosts to get them on-network
```

### Forge
The **forge** is responsible for monitoring and coordinating all other nodes on
the system. It handles:

- Behind-the-firewall DNS resolution via CoreDNS
- Service registry: queries nodes to track their exposed services
- Container image caching via Zot (`containers.${domain}`)
- SSL certificate retrieval and distribution for the network
- Observability stack (Prometheus, Grafana, Loki)
- Git hosting via Forgejo with CI/CD via Actions

### CI/CD Pipeline

The forge runs Forgejo Actions workflows that automate the release process. A dedicated **CI age key** is used to decrypt secrets during CI:

- **Public key**: Stored in `clusters/<cluster>/manifest.nix` as `ciAgeKey`
- **Private key**: Stored ONLY in Forgejo repository secrets as `CI_AGE_KEY`

The release workflow (`release.yml`) runs on pushes to `main`:
1. Evaluates each host's agenix config to determine required secrets
2. Re-keys secrets for their target devices
3. Pushes to `release` branch

To regenerate the CI key (if compromised or rotating):
```bash
nix shell nixpkgs#age -c age-keygen
# Update ciAgeKey in cluster manifest with the public key
# Update CI_AGE_KEY in Forgejo secrets with the private key
# Re-key all secrets: nix run .#agenix -- -i ~/.ssh/fort -r
```

## Available Apps

Fort includes modules for deploying a variety of self-hosted applications:

| App | Description |
|-----|-------------|
| actualbudget | Self-hosted budgeting software |
| audiobookshelf | Audiobook and podcast server |
| calibre-web | E-book management web interface |
| coredns | Internal DNS for the mesh network |
| fort-observability | Prometheus, Grafana, and Loki stack |
| headscale | Self-hosted Tailscale control server |
| home-assistant | Home automation platform with Zigbee2MQTT integration |
| homepage | Customizable dashboard |
| jellyfin | Media streaming server |
| lidarr, radarr, readarr, sonarr | Media management (*arr stack) |
| ollama | Local LLM inference |
| open-webui | Web interface for Ollama |
| outline | Team knowledge base and wiki |
| pocket-id | SSO/OIDC identity provider backed by LDAP |
| prowlarr | Indexer manager for *arr apps |
| qbittorrent | BitTorrent client |
| sillytavern | LLM chat frontend |
| super-productivity | Task and time management |
| vikunja | Task and project management |
| zot | OCI container registry |

## Available Aspects

Aspects are host characteristics that can be composed together:

| Aspect | Description |
|--------|-------------|
| certificate-broker | Manages SSL certificate distribution |
| deployer | Enables deploy-rs for host deployments |
| egress-vpn | Routes traffic through external VPN |
| ldap | LLDAP directory service with bootstrapped users/groups |
| mesh | Tailscale mesh network membership |
| mosquitto | MQTT broker for IoT devices |
| observable | Prometheus node exporter and log shipping |
| public-ingress | Public-facing nginx reverse proxy (beacon) |
| service-registry | Discovers and tracks cluster services |
| wifi-access | WiFi network configuration |
| zfs | ZFS filesystem support |
| zigbee2mqtt | Zigbee device gateway |
| zwave-js-ui | Z-Wave device gateway |

## Setting Up a New Host

Setting up a host can be done in a few minutes by following these steps.

### Provisioning a Host

First, ensure that you have a reasonable device profile set up for the hardware
you're establishing. Then boot up the device, make any BIOS changes you may
desire (ensuring it always reboots, and that it boots after power loss can be
helpful), and boot the device into any environment with SSH root access open.
The Ubuntu Server LiveISO is one example (Ctrl + Alt + F3 to hop into a fresh
TTY and skip the installer) - just tweak your sshd_config, disable ufw, and
start ssh.

```bash
just provision <device-type> <ip>
# e.g. just provision beelink 192.168.1.42
```

This will attempt to pull a unique fingerprint for the device and write a flake
under `./clusters/<cluster>/devices/<uuid>` given that id. It will leverage
nixos-anywhere to convert your machine into a NixOS box that you can assign as
a host and deploy to.

### Assigning a Host

For a provisioned device, we can create a host flake setup.

```bash
just assign <device> <hostname>
# e.g. just assign f848d467-b339-4b5d-a8a0-de1ea07ba304 marmaduke
```

This writes out the flake and additional files to `./clusters/<cluster>/hosts/<hostname>`,
where you can subsequently tweak the `manifest.nix` file. It's recommended that
you deploy the initial template _first_, so that subsequent deploys can be done
over VPN.

### Deploying a Host

If a host has been deployed once, it can be deployed again over the mesh
network. But for the initial deploy, you'll need to provide the target IP
address once more.

```bash
just deploy <hostname> <ip>
# e.g. just deploy marmaduke 192.168.1.42
```

When the `ip` value is omitted, it's assumed that you're targeting
`<hostname>.fort.<base domain>`. You'll likely want to put your development box
on the mesh network ASAP to ensure those resolve for you.

### Validating Changes

Run `just test` regularly to execute `nix flake check` against the root flake
and every host/device in the selected cluster. This command respects both
`CLUSTER` and `.cluster`, so be sure the correct cluster is selected before
running it.

## Other Commands

| Command | Description |
|---------|-------------|
| `just fmt` | Format all Nix files with nixfmt |
| `just ssh <host>` | SSH into a host using the deploy key |
| `just age <path>` | Edit an age-encrypted secret file |

## IoT and Home Automation

Fort supports declarative Home Assistant configuration with:

- **Zigbee2MQTT**: Zigbee device gateway with declarative device naming
- **Z-Wave JS UI**: Z-Wave device gateway with declarative device naming
- **Mosquitto**: MQTT broker for device communication
- **Home Assistant**: Automations, scenes, and scripts defined in Nix

IoT device manifests are encrypted and can define both Zigbee and Z-Wave devices with friendly names. The manifest format supports both device types:

```
# Zigbee devices use IEEE address
0x00158d00xxxxxxxx:script_name:Friendly Name

# Z-Wave devices use DSK (note: name cannot contain spaces)
00000-00000-00000-00000-00000-00000-00000-00000:script_name:FriendlyName
```
