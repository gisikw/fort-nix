---
id: fort-89e.1
status: closed
deps: []
links: []
created: 2025-12-30T22:00:42.251940795Z
type: task
priority: 2
parent: fort-89e
---
# Agent Nix module skeleton

Create aspects/fort-agent/ module structure:
- Generate /etc/fort-agent/ directory (handlers/, rbac.json, hosts.json with peer public keys)
- Nginx location for /agent/* → FastCGI socket
- Systemd socket activation for wrapper
- Wire host SSH keys from cluster topology into hosts.json

This is the foundation - no actual wrapper implementation yet, just scaffolding.

## Acceptance Criteria

- /etc/fort-agent/ structure exists on hosts with fort-agent enabled
- nginx routes /agent/* to FastCGI socket
- hosts.json contains peer public keys from cluster topology


