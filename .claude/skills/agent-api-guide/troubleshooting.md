# Troubleshooting Agent Calls

## Common Errors

### "auth error" (exit code 2)

**Symptoms:**
```json
{"body": "unauthorized", "status": 401}
```

**Causes & fixes:**

1. **Unknown origin**: Caller not in `hosts.json`
   - Check `/etc/fort-agent/hosts.json` on target
   - Verify caller has `agentKey` in principals or is a cluster host

2. **Invalid signature**: Key mismatch
   - Verify `FORT_SSH_KEY` points to correct private key
   - Check that public key in `hosts.json` matches

3. **Timestamp drift**: Clocks out of sync
   - Wrapper rejects if drift > 5 minutes
   - Check `timedatectl` on both hosts

### "not authorized for capability" (403)

**Symptoms:**
```json
{"body": "forbidden", "status": 403}
```

**Cause**: Caller not in RBAC list for this capability.

**Fix**: Add a `fort.host.needs` declaration that references this capability:

```nix
fort.host.needs.the-capability.my-id = {
  providers = ["target-host"];
};
```

Then rebuild. RBAC is computed from `fort.host.needs` declarations.

### "capability not found" (404)

**Symptoms:**
```json
{"body": "not found", "status": 404}
```

**Causes:**
1. Capability doesn't exist on target host
2. Handler script not installed

**Debug:**
```bash
# Check what capabilities exist
fort-agent-call hostname manifest '{}' | jq '.body.capabilities'

# Check handler directory on host
ls /etc/fort-agent/handlers/
```

### Handler failures (500)

**Symptoms:**
```json
{"body": "internal error", "status": 500}
```

**Debug:**
```bash
# Check wrapper logs
journalctl -u fort-agent-wrapper -n 50

# Test handler directly on host
echo '{}' | /etc/fort-agent/handlers/my-capability
```

## Environment Variables

For dev-sandbox callers:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FORT_SSH_KEY` | `/var/lib/fort/dev-sandbox/agent-key` | Path to signing key |
| `FORT_ORIGIN` | `dev-sandbox` | Caller identity |

For host-to-host callers:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FORT_SSH_KEY` | `/etc/ssh/ssh_host_ed25519_key` | Host SSH key |
| `FORT_ORIGIN` | `$(hostname -s)` | Hostname |

## Checking RBAC Configuration

```bash
# On target host
cat /etc/fort-agent/rbac.json | jq '.'

# Shows which callers can access which capabilities
# {
#   "status": ["host1", "host2", "dev-sandbox"],
#   "oidc-register": ["host1", "host2"]
# }
```

## Checking Known Hosts

```bash
# On target host
cat /etc/fort-agent/hosts.json | jq '.'

# Shows known callers and their public keys
# {
#   "host1": {"pubkey": "ssh-ed25519 AAAA..."},
#   "dev-sandbox": {"pubkey": "ssh-ed25519 BBBB..."}
# }
```

## Manual Request Signing (debugging)

To understand the signing process:

```bash
# Create canonical string
timestamp=$(date +%s)
body='{}'
body_hash=$(echo -n "$body" | sha256sum | cut -d' ' -f1)
canonical="POST\n/agent/status\n${timestamp}\n${body_hash}"

# Sign it
echo -e "$canonical" | ssh-keygen -Y sign \
  -f /var/lib/fort/dev-sandbox/agent-key \
  -n fort-agent -

# This produces an SSH signature block that fort-agent-call base64-encodes
```

## Nginx Layer Issues

The agent endpoint is served via nginx FastCGI. Check:

```bash
# Nginx config
cat /etc/nginx/sites-enabled/*agent* 2>/dev/null || grep -r agent /etc/nginx/

# FastCGI socket
ls -la /run/fort-agent/fcgi.sock

# Wrapper service
systemctl status fort-agent-wrapper
```

## Capability Not Showing Up

If you added a capability but it's not available:

1. **Rebuild happened?** Check deploy timestamp:
   ```bash
   fort-agent-call hostname status '{}' | jq '.body.deploy'
   ```

2. **Handler installed?**
   ```bash
   ls /etc/fort-agent/handlers/
   ```

3. **Capability in config?**
   ```bash
   cat /etc/fort-agent/capabilities.json
   ```
