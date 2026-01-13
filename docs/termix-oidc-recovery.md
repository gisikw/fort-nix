# Termix OIDC Configuration via Direct DB Injection

**Status**: Implementation Plan
**Ticket**: fort-c8y.34
**Date**: 2026-01-13

## Problem Statement

The current termix bootstrap uses the API to configure OIDC, then disables password login. If OIDC credentials get rotated/invalidated, there's no recovery path - can't log in to reconfigure. Current fix requires nuking all state.

**Constraints:**
- Endpoint is public (accessible from outside VPN)
- Registration must stay open (disabling it breaks OIDC for new users)
- Password login should stay disabled (cleaner UX - avoids extra click to reach OIDC)

## Solution: Direct Database Manipulation

Instead of using the termix API, we inject OIDC configuration directly into the SQLite database. This bypasses authentication entirely, making credential rotation seamless.

### Termix Database Architecture

Termix uses an **in-memory SQLite database** with periodic encrypted snapshots:

- On startup: Decrypts `db.sqlite.encrypted` → loads into memory
- While running: Flushes to encrypted file every **15 seconds**
- On shutdown: SIGTERM triggers final flush before exit

**Encryption**: AES-256-GCM with key from `DATABASE_KEY` in `/var/lib/termix/.env`

**File format** (single-file v2):
```
[4 bytes: metadata length (big-endian)]
[N bytes: JSON metadata {iv, tag, version, algorithm}]
[remaining: encrypted SQLite data]
```

**Implication**: Must stop termix before modifying the DB file, otherwise changes get overwritten.

### Relevant Schema

```sql
-- Global settings including OIDC config
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Key rows:
-- 'oidc_config' → JSON with client_id, client_secret, issuer_url, etc.
-- 'allow_password_login' → 'true' or 'false'
-- 'allow_registration' → 'true' or 'false'

-- Users table (first created user gets is_admin=1)
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    is_admin INTEGER NOT NULL DEFAULT 0,
    ...
);
```

## Implementation

### Initial Provisioning Flow

```
1. Start termix container (fresh, no encrypted DB exists)
2. Wait for termix to be healthy
3. POST /users/create with throwaway credentials
   └── Burns "first user is admin" - we don't need these creds
4. Stop termix container (triggers flush to encrypted file)
5. Wait for OIDC credentials from control plane
6. Decrypt DB → Patch settings → Re-encrypt DB:
   - INSERT/UPDATE oidc_config with OIDC credentials JSON
   - UPDATE allow_password_login = 'false'
7. Start termix container
8. Write client_id to marker file for change detection
```

### Credential Rotation Flow

```
1. Control plane delivers new OIDC credentials
2. Compare new client_id to marker file
3. If changed:
   a. Stop termix container
   b. Decrypt DB
   c. UPDATE oidc_config with new credentials JSON
   d. Re-encrypt DB
   e. Start termix container
   f. Update marker file
```

### Database Operations Script

```bash
#!/usr/bin/env bash
# termix-db-patch.sh - Decrypt, patch OIDC config, re-encrypt

set -euo pipefail

TERMIX_DATA="/var/lib/termix"
ENCRYPTED_DB="$TERMIX_DATA/db.sqlite.encrypted"
TMP_DB="/tmp/termix-patched.sqlite"
CLIENT_ID="$1"
CLIENT_SECRET="$2"
ISSUER_URL="$3"

# Read encryption key
KEY=$(grep DATABASE_KEY "$TERMIX_DATA/.env" | cut -d'=' -f2)

# Decrypt to temp file
node /path/to/decrypt-termix.mjs "$ENCRYPTED_DB" "$KEY" "$TMP_DB"

# Build OIDC config JSON
OIDC_CONFIG=$(jq -n \
  --arg cid "$CLIENT_ID" \
  --arg cs "$CLIENT_SECRET" \
  --arg iss "$ISSUER_URL" \
  '{
    client_id: $cid,
    client_secret: $cs,
    issuer_url: $iss,
    authorization_url: ($iss + "/authorize"),
    token_url: ($iss + "/api/oidc/token"),
    userinfo_url: ($iss + "/api/oidc/userinfo"),
    identifier_path: "sub",
    name_path: "preferred_username",
    scopes: "openid email profile"
  }')

# Patch the database
sqlite3 "$TMP_DB" <<EOF
INSERT OR REPLACE INTO settings (key, value) VALUES ('oidc_config', '$OIDC_CONFIG');
INSERT OR REPLACE INTO settings (key, value) VALUES ('allow_password_login', 'false');
EOF

# Re-encrypt
node /path/to/encrypt-termix.mjs "$TMP_DB" "$KEY" "$ENCRYPTED_DB"

# Cleanup
rm -f "$TMP_DB"
```

### Node.js Decrypt/Encrypt Helpers

**decrypt-termix.mjs:**
```javascript
import crypto from 'crypto';
import fs from 'fs';

const [encPath, keyHex, outPath] = process.argv.slice(2);
const fileBuffer = fs.readFileSync(encPath);
const metaLen = fileBuffer.readUInt32BE(0);
const metadata = JSON.parse(fileBuffer.slice(4, 4 + metaLen).toString('utf8'));
const encData = fileBuffer.slice(4 + metaLen);

const decipher = crypto.createDecipheriv('aes-256-gcm',
  Buffer.from(keyHex, 'hex'),
  Buffer.from(metadata.iv, 'hex'));
decipher.setAuthTag(Buffer.from(metadata.tag, 'hex'));
const decrypted = Buffer.concat([decipher.update(encData), decipher.final()]);

fs.writeFileSync(outPath, decrypted);
```

**encrypt-termix.mjs:**
```javascript
import crypto from 'crypto';
import fs from 'fs';

const [inPath, keyHex, outPath] = process.argv.slice(2);
const plaintext = fs.readFileSync(inPath);
const key = Buffer.from(keyHex, 'hex');
const iv = crypto.randomBytes(16);

const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
const tag = cipher.getAuthTag();

const metadata = JSON.stringify({
  iv: iv.toString('hex'),
  tag: tag.toString('hex'),
  version: 'v2',
  fingerprint: 'termix-v2-systemcrypto',
  algorithm: 'aes-256-gcm',
  keySource: 'SystemCrypto',
  dataSize: encrypted.length
});

const metaBuffer = Buffer.from(metadata, 'utf8');
const lenBuffer = Buffer.alloc(4);
lenBuffer.writeUInt32BE(metaBuffer.length, 0);

fs.writeFileSync(outPath, Buffer.concat([lenBuffer, metaBuffer, encrypted]));
```

## Changes to apps/termix/default.nix

### Remove from bootstrap script:
- Login with admin credentials
- POST to `/users/oidc-config`
- PATCH to `/users/password-login-allowed`
- Storage of admin credentials (no longer needed)

### Add new components:

1. **termix-db-tools package**: Node.js scripts for decrypt/encrypt
2. **termix-oidc-provision service**: Initial setup after first boot
3. **termix-oidc-sync service**: Credential rotation handler

### Service orchestration:

```
podman-termix.service
    │
    ├── termix-oidc-provision.service (oneshot, first boot only)
    │   └── Creates throwaway admin, stops container, patches DB, restarts
    │
    └── [control plane callback]
        └── termix-oidc-sync (stops container, patches DB, restarts)
```

## Migration Path

For existing termix installations:

1. Deploy new code (services won't run yet - marker files don't exist)
2. Manual one-time migration:
   - Stop termix
   - Run DB patch script with current OIDC creds
   - Create marker file with current client_id
   - Start termix
3. Future credential rotations handled automatically

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Schema changes in upstream termix | Pin to known version; test upgrades before deploying |
| Encryption format changes | Version check in decrypt script; fail loudly if unexpected |
| Race between flush and stop | Use `systemctl stop` which sends SIGTERM, triggering clean shutdown |
| Corrupt DB during patch | Atomic file replacement (write to temp, rename) |

## References

- `/tmp/termix-src/src/backend/database/db/index.ts` - DB lifecycle (in-memory, 15s flush)
- `/tmp/termix-src/src/backend/utils/database-file-encryption.ts` - Encryption format
- `/tmp/termix-src/src/backend/utils/system-crypto.ts` - Key handling
- `apps/termix/default.nix` - Current bootstrap (to be replaced)
