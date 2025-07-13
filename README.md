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
```
