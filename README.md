# Fort Nix

A declarative nix-based homelab configuration using nixos-anywhere and deploy-rs.

## Layered Host Configuration

Fort now supports multiple clusters simultaneously. Set the active cluster by
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
    - Defined in `./device-profiles/<profile>`
- A **device entry**: Unique machine binding by UUID
    - Auto-generated in `./clusters/<cluster>/devices/<uuid>`
- A **host**: Logical identity, tied to a device UUID
    - Scaffolded under `./clusters/<cluster>/hosts/<name>`, with primary configuration via `manifest.nix`
    - Composed of:
        - **Aspects**: characteristics of the given host (e.g. `wifi-access`,
        `observable`, `mesh`)
        - **Apps**: apps that are deployed on the host (e.g. `jellyfin`,
        `actual-budget`, `home-assistant`)
        - **Roles**: predefined sets of aspects and apps

## Setting Up the Cluster

The cluster itself depends on two "hero" roles that need to be provisioned
before any others:

### Beacon
The **beacon** is a host that exists as a coordination server for the mesh
network. This is the box to which public DNS is pointed, and as of today, it
runs headscale. While you _could_ run this device on your home network, that
would risk exposing your residential IP address, which has security
implications. But a minimal VPS is sufficient for handling this workload.

Once the beacon is created, you'll want to issue a preauthorization key so that
additional nodes can be added to the mesh network, like so:

```bash
headscale users create fort
headscale preauthkeys create --user fort --reusable --expiration 99y
# Put the value in tailscale/auth-key.age
# Redeploy both the beacon host and any other hosts to get them on-network
```

### Forge
The **forge** is responsible for monitoring all other nodes on the system. It
handles behind-the-firewall DNS resolution, queries other nodes to track their
exposed services, caches container images so they can be pinned long-term, and
handles SSL certificate retrieval and distribution for the network.

## Setting Up a New Host

Setting up a host can be done in the order of a few minutes by following a few steps.

### Provisioning a Host

First, ensure that you have a reasonable device profile set up for the hardware
you're establishing. Then boot up the device, make any BIOS changes you may
desire (ensuring it always reboots, and that it boots after power loss can be
helpful), and boot the device into any environment with SSH root access open.
The Ubuntu Server LiveISO is one example among many (Ctrl + Alt + F3 to hop
into a fresh TTY and skip the installer) - just tweak your sshd_config, disable
ufw, and start ssh.

```bash
just provision <device-type> <ip>
# e.g. just provision beelink 192.168.1.42
```

This will attempt to pull a unique fingerprint for the device and write a flake
under `./clusters/<cluster>/devices/<uuid>` given that id. It will leverage nixos-anywhere to
convert your machine into a NixOS box that you can assign as a host and deploy
to.

### Assigning a Host

For a provisioned device, we can create a host flake setup.

```bash
just assign <device> <hostname>
# e.g. just assign f848d467-b339-4b5d-a8a0-de1ea07ba304 marmaduke
```

This writes out the flake and additional files to `./clusters/<cluster>/hosts/<hostname>`, where
you can subsequently tweak the `manifest.nix` file. It's recommended that you
deploy the initial template _first_, so that subsequent deploys can be done
over VPN.

### Deploying a Host

If a host has been deployed once, it can be deployed again over the mesh
network. But for the initial deploy, you'll need to provide the target IP
address once more.

```bash
just deploy <hostname> <ip>
# e.g. just deploy markmaduke 192.168.1.42
```

When the `ip` value is omitting, it's assumed that you're targeting
`<hostname>.fort.<base domain>`. You'll likely want to put your development box
on the mesh network ASAP to ensure those resolve for you.

### Validating Changes

Run `just test` regularly to execute `nix flake check` against the root flake
and every host/device in the selected cluster. This command respects both
`CLUSTER` and `.cluster`, so be sure the correct cluster is selected before
running it.
