# Garbage Collection Protocol

Some capabilities create server-side state (OIDC clients, tokens, etc.). The GC protocol ensures this state is cleaned up when no longer needed.

## Overview

1. **Provider** creates state with a handle (content-addressed SHA256)
2. **Consumer** stores the handle and reports it via `/agent/holdings`
3. **Provider** periodically checks holdings; if handle absent, eligible for GC

## Enabling GC

```nix
fort.capabilities.my-capability = {
  handler = ./handlers/my-capability;
  needsGC = true;   # Enable handle tracking
  ttl = 86400;      # 24-hour lease
};
```

## Handle Generation

When `needsGC = true`, `fort-agent-wrapper`:

1. Executes the handler
2. Computes SHA256 of response body
3. Creates handle: `sha256:<hex-digest>`
4. Stores response at `/var/lib/fort-agent/handles/sha256-<hex>/response`
5. Stores metadata at `/var/lib/fort-agent/handles/sha256-<hex>/.meta`
6. Returns `X-Fort-Handle` and `X-Fort-TTL` headers

## Consumer Side

Consumers using `fort.needs` automatically:

1. Store the response at the configured `store` path
2. Track the handle in `/var/lib/fort/holdings.json`
3. Report holdings when queried via `/agent/holdings`

## Manual Consumer

If not using `fort.needs`, track handles manually:

```bash
# Make request
response=$(fort-agent-call provider my-capability '{}')
handle=$(echo "$response" | jq -r '.handle')
body=$(echo "$response" | jq -r '.body')

# Store response
echo "$body" > /var/lib/myapp/response.json

# Track handle (append to holdings)
jq --arg h "$handle" '. += [$h] | unique' /var/lib/fort/holdings.json > tmp
mv tmp /var/lib/fort/holdings.json
```

## GC Process (Provider Side)

The provider runs a timer that:

1. Lists all handles in `/var/lib/fort-agent/handles/`
2. For each handle, queries consumers via `/agent/holdings`
3. If handle present in holdings: renew TTL
4. If handle absent AND TTL expired: delete state

**Two Generals Safety**: Only delete on positive absence (200 OK with handle not in list). Never delete on connection failure or timeout.

## TTL Semantics

- TTL is a "lease" - how long to keep state without confirmation
- Each successful holdings check renews the TTL
- TTL countdown starts when handle is created
- Short TTL (1 hour): aggressive cleanup, more network chatter
- Long TTL (24 hours): less chatter, slower cleanup

## Example: OIDC Client Lifecycle

1. **Create**: Host A calls `oidc-register` on Identity Provider
2. **Response**: IP creates OIDC client, returns credentials, handle = `sha256:abc123`
3. **Store**: Host A stores credentials in `/var/lib/fort-auth/myapp/`
4. **Track**: Host A adds `sha256:abc123` to holdings.json
5. **Poll**: IP timer checks Host A's holdings - handle present, TTL renewed
6. **Remove**: Host A is decommissioned, no longer reports holdings
7. **GC**: IP timer sees handle absent, TTL expires, deletes OIDC client

## Debugging

Check holdings on a host:

```bash
fort-agent-call hostname holdings '{}'
```

Check handle state on provider:

```bash
ls -la /var/lib/fort-agent/handles/
cat /var/lib/fort-agent/handles/sha256-abc123/.meta
```
