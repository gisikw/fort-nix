# Fort-Nix

Homelab configuration using nixos-anywhere and deploy-rs.

## Dependencies
* [Nix](https://nixos.org/)
* [Just](https://github.com/casey/just)
* A hardwired machine with root SSH access

## Usage

```sh
# Set up your ssh key
just init

# Deploy nix to your device
just provision beelink root@192.168.1.1

# Assign the newly provisioned device to a host
just assign <uuid> <host>

# Deploy host configuration
just deploy <host>
```

## Layered Configuration

The configuration for a host is composed of several layers:

- A **device profile**: Base-level image configuration (e.g., Wifi, disk layout)
    - Defined in `./device-profiles/<profile>`
- A **device entry**: Unique machine binding by UUID
    - Auto-generated in `./devices/<uuid>`
- A **host**: Logical identity, tied to a device UUID
    - Defined in `config.toml` under `[hosts.<name>]`
    - Composed of:
        - **Roles**: Higher-order configuration bundles written in Nix
            - e.g. `fort-host` may include custom behaviors like DNS registration
            - Declarable in `config.toml`, though some default roles (like `fort-host`) are auto-applied
            - Roles may declare various drivers, features, and service configurations for their members
        - **Drivers / Features / Services**: Atomic, composable units
            - Declared in `config.toml` at the host level
            - Used to express peripheral support, host capabilities, and specific daemons

**Roles** are how we declare shared behaviors across a cohort.
**Drivers / Features / Services** are how we assign behaviors to a specific host.

## Provisioning

Provisioning a host requires only a device profile. This step performs a full wipe and fresh NixOS install using `nixos-anywhere`.

The target of `just provision` is an IP address or hostname reachable over SSH - it is _not_ a fully configured "host" yet.

As part of provisioning, a new `uuid` is generated and added to `config.toml`
under the `[devices]` section. If you're provisioning new hardware, copy an
existing `device-profile` as a starting point and adjust it for your needs.

## Deployment

After assigning a device UUID to a logical host name via `just assign`, future deployments use `deploy-rs`. These updates:

- Are faster and safer than full reprovisioning
- Will attempt to safely rollback if there are errors in the configuration
- Will **not** repartition disks or reflash the base system image
