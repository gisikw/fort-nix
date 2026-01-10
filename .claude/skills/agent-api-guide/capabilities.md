# Adding Capabilities

Capabilities are endpoints that a host exposes for other hosts to call.

## Basic Structure

In your app or aspect module:

```nix
{ config, ... }:

{
  fort.host.capabilities.my-capability = {
    handler = ./handlers/my-capability;
    description = "Brief description of what this does";
  };
}
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `handler` | path | required | Script that handles requests |
| `needsGC` | bool | `false` | Enable garbage collection |
| `ttl` | int | `0` | GC time-to-live in seconds |
| `satisfies` | string | `null` | Which `fort.host.needs` type this satisfies |
| `description` | string | `""` | Human-readable description |

## Working Example: OIDC Registration

From `apps/pocket-id/default.nix`:

```nix
fort.host.capabilities.oidc-register = {
  handler = ./handlers/oidc-register;
  needsGC = true;
  ttl = 86400;  # 24 hours
  description = "Register OIDC client in pocket-id";
};
```

## RBAC: Who Can Call?

RBAC is computed automatically from the cluster topology:

1. Host A declares `fort.host.needs.my-capability.foo.providers = ["host-b"]`
2. At eval time, `fort-agent.nix` adds Host A to `rbac.json` for `my-capability` on Host B
3. Only Host A can call `/agent/my-capability` on Host B

This means **capabilities don't need explicit ACLs** - the topology IS the authorization.

## Standard Capabilities

These are always available on all hosts (defined in `fort-agent.nix`):

```nix
fort.host.capabilities = {
  status = {
    handler = writeShellScript "status-handler" ''cat /var/lib/fort/status/status.json'';
    description = "Host status (uptime, failed units, deploy info)";
  };
  manifest = {
    handler = writeShellScript "manifest-handler" ''cat /var/lib/fort/host-manifest.json'';
    description = "Host manifest (apps, aspects, roles)";
  };
  holdings = {
    handler = writeShellScript "holdings-handler" ''cat /var/lib/fort/holdings.json'';
    description = "GC handles currently held by this host";
  };
};
```

## Adding New Standard Capabilities

If a capability should be on ALL hosts, add it to `common/fort-agent.nix`. If it's specific to an app or aspect, define it in that module.

## Testing a Capability

From the dev-sandbox:

```bash
# Check what capabilities a host exposes
fort drhorrible manifest | jq '.body.capabilities'

# Call your capability
fort hostname my-capability '{"key": "value"}'
```
