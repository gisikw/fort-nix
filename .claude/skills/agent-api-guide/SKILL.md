---
name: agent-api-guide
description: Guide for the inter-host agent API system. Use when adding capabilities to hosts, writing handlers, understanding the GC protocol, or debugging agent call issues.
---

# Agent API Guide

This skill covers the fort-agent system for secure inter-host communication. Hosts can expose capabilities that other hosts call via signed HTTP requests.

## Quick Reference

**Client (calling a capability):**
```bash
fort <host> <capability> [request-json]  # request-json defaults to '{}'
```

Examples:
```bash
fort drhorrible status                    # No args needed for simple calls
fort joker journal '{"unit": "nginx"}'    # Pass JSON when capability needs params
```

**Provider (exposing a capability):**
```nix
fort.host.capabilities.my-capability = {
  handler = ./handlers/my-capability;  # Script that handles requests
  needsGC = false;                      # Enable garbage collection
  ttl = 0;                              # GC time-to-live in seconds
  description = "What this does";
};
```

**Consumer (depending on a capability):**
```nix
fort.host.needs.my-capability.my-id = {
  providers = ["hostname"];             # Host(s) providing this
  request = { key = "value"; };         # Request payload
  store = "/var/lib/myapp/response";    # Where to store response
  restart = ["myapp.service"];          # Services to restart on change
};
```

## Key Files

| Path | Purpose |
|------|---------|
| `common/fort-agent.nix` | Nix module defining options and config generation |
| `pkgs/fort/` | Client CLI (Bash) |
| `pkgs/fort-provider/` | Server (Go FastCGI) |
| `/etc/fort-agent/` | Runtime config on hosts |
| `/var/lib/fort-agent/` | GC handles and state |

## Detailed Documentation

- [capabilities.md](capabilities.md) - Adding capabilities to hosts
- [handlers.md](handlers.md) - Writing handler scripts
- [gc-protocol.md](gc-protocol.md) - Garbage collection system
- [troubleshooting.md](troubleshooting.md) - Debugging issues

## Standard Capabilities

All hosts expose these capabilities:

| Capability | Returns |
|------------|---------|
| `status` | Hostname, uptime, failed units, deploy info |
| `manifest` | Apps, aspects, roles, exposed services |
| `holdings` | GC handles currently in use |

## Authentication & RBAC

- Requests signed with SSH keys (`ssh-keygen -Y sign`)
- RBAC computed at eval time from cluster topology
- Only hosts that `fort.host.needs` a capability can call it
- Config files: `/etc/fort-agent/hosts.json`, `/etc/fort-agent/rbac.json`
