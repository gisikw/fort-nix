# Termix OIDC Self-Jailing Recovery

**Status**: Research / Design
**Ticket**: fort-c8y.34
**Date**: 2026-01-13

## Problem Statement

The termix bootstrap disables password login after configuring OIDC. If OIDC credentials get rotated/invalidated (e.g., pocket-id state reset), there's no recovery path:

1. Password login is globally disabled
2. OIDC validation fails (client_id/secret invalid)
3. Can't log in to reconfigure OIDC
4. Current fix: nuke `/var/lib/termix/*` and lose all state

## Technical Context

### Termix Auth Model

- **Storage**: Encrypted SQLite database
- **Password hashing**: bcrypt
- **First user is admin**: The first `/users/create` call gets `is_admin=true`
- **Global password toggle**: `PATCH /users/password-login-allowed` affects ALL users
- **No per-user exceptions**: Can't keep admin password login while disabling others

### Current Bootstrap Flow (apps/termix/default.nix)

```
1. Create local admin user (fort-admin) with random password
2. Wait for OIDC credentials from pocket-id
3. Login with local admin to get JWT
4. POST OIDC config to termix
5. Disable password login globally  ← Creates the jail
6. Mark OIDC as configured
```

### Failure Scenario

```
pocket-id state reset (e.g., beads nuke)
    ↓
termix client_id/secret now invalid
    ↓
OIDC auth fails (can't validate tokens)
    ↓
Password login disabled
    ↓
No way in → Must destroy state
```

## Approaches Analyzed

### Approach A: OIDC Admin Account (User's Initial Suggestion)

**Concept**: Make the admin user an OIDC user, not a local user.

**Flow**:
1. Create local admin user (temporary)
2. Enable OIDC
3. Log in via OIDC with pocket-id service account → creates OIDC user in termix
4. Promote OIDC user to admin via local admin session
5. Disable password login
6. Future admin access via OIDC

**Problem**: This doesn't solve the core issue. When termix's OIDC client credentials become invalid, termix can't validate *any* OIDC tokens, including the admin's. The failure is at the termix↔pocket-id client level, not the user identity level.

**Verdict**: ❌ Does not address the failure mode.

---

### Approach B: External OIDC Config Injection

**Concept**: Bypass termix's API entirely. Inject OIDC config directly into the database or via environment variables on startup.

**Flow**:
1. Termix starts with OIDC config from external source (control plane)
2. When credentials rotate, control plane pushes new config
3. Termix restart picks up new config
4. No need to authenticate to reconfigure

**Implementation Options**:

1. **Database injection**: Write directly to termix's SQLite
   - Risk: Schema changes in upstream could break us
   - Risk: Database encryption complicates direct writes
   - Requires reverse-engineering the schema

2. **Config file**: If termix supports file-based config
   - Unknown: Upstream docs don't document this
   - Would need to test or patch termix

3. **Environment variables**: Pass OIDC config via env
   - Unknown: Upstream doesn't document env-based OIDC config
   - Would need to patch termix

**Verdict**: ⚠️ Potentially viable but requires upstream investigation or patching. High fragility risk if using undocumented interfaces.

---

### Approach C: Detect-and-Recover Service

**Concept**: A watchdog service that detects OIDC failure and initiates recovery.

**Flow**:
1. Systemd service periodically tests OIDC health
2. On failure detection:
   - Re-enable password login (direct DB write or emergency API)
   - Login with stored admin credentials
   - Fetch fresh OIDC credentials from pocket-id
   - Reconfigure OIDC
   - Disable password login again

**Requirements**:
- Ability to re-enable password login without authentication
- Either: Direct DB manipulation, or patched emergency endpoint

**Complexity**:
- Health check logic (distinguish transient vs permanent failure)
- Race conditions during recovery
- DB manipulation adds fragility

**Verdict**: ⚠️ Viable but complex. Still requires either DB manipulation or upstream patch.

---

### Approach D: Keep Password Login Enabled

**Concept**: Don't disable password login at all.

**Flow**:
1. Create local admin with strong random password
2. Configure OIDC as primary login method
3. Keep password login enabled
4. Regular users use OIDC; admin password is emergency backdoor

**Trade-offs**:
- ✅ Simple, no upstream changes needed
- ✅ Always recoverable
- ❌ Password auth remains enabled for all users
- ❌ Attack surface: password-based attacks on any user
- ❌ Users might create local accounts instead of using SSO

**Mitigation**: Could disable registration while keeping password login enabled. New users must come through OIDC, but existing local admin can still log in.

**Verdict**: ✅ Simplest solution. Acceptable if we disable registration.

---

### Approach E: Upstream Patch - Per-User Password Exception

**Concept**: Patch termix to support per-user password login override.

**Implementation**:
- Add `password_login_override` field to users table
- Admin user gets `password_login_override = true`
- Global toggle only affects users without override

**Trade-offs**:
- ✅ Clean solution, maintains security posture
- ✅ Admin backdoor without exposing other users
- ❌ Requires upstream PR (may not be accepted)
- ❌ Or maintaining a fork
- ❌ Patch maintenance burden

**Verdict**: ⚠️ Best long-term solution but requires upstream engagement or fork maintenance.

---

### Approach F: Emergency Backdoor Endpoint

**Concept**: Patch termix to add a local-only emergency endpoint.

**Implementation**:
- New endpoint: `POST /emergency/oidc-config`
- Only accepts requests from localhost
- Authenticates via secret file on disk (e.g., `/var/lib/termix/emergency-key`)
- Allows OIDC reconfiguration without normal auth

**Trade-offs**:
- ✅ Minimal attack surface (localhost only + file secret)
- ✅ Doesn't weaken normal auth model
- ❌ Requires upstream patch or fork
- ❌ Non-standard pattern (may not be accepted upstream)

**Verdict**: ⚠️ Elegant but requires patching termix.

---

### Approach G: Pocket-ID Service Account Token Provider

**Concept**: Expose pocket-id admin credentials via control plane for termix recovery.

**Flow**:
1. pocket-id exposes a `termix-recovery` capability
2. Returns: API key for a service account, or fresh OTC
3. termix-recovery service on the termix host:
   - Detects OIDC failure
   - Requests recovery credentials from pocket-id
   - Uses pocket-id API to create fresh OIDC client
   - Injects new client_id/secret into termix

**Problem**: This still requires a way to inject the new credentials into termix. We're back to approaches B/C.

**Verdict**: ⚠️ Addresses credential provisioning but not injection. Must combine with another approach.

---

## Recommendation

### Short-term (no upstream changes): Approach D

1. Remove the password login disable step from bootstrap
2. Add `registration-disabled` setting (if termix supports it) to prevent new local accounts
3. Document that admin password is emergency recovery only
4. Store admin credentials securely in `/var/lib/termix/admin-credentials.json`

**Changes required**:
- `apps/termix/default.nix`: Remove lines 164-168 (password disable)
- Investigate termix registration settings

### Long-term (with upstream engagement): Approach E or F

1. File upstream issue/PR for per-user password exception OR emergency endpoint
2. If accepted: Update our bootstrap to use the new mechanism
3. If rejected: Evaluate fork maintenance cost vs security benefit

---

## Open Questions

1. **Does termix support disabling registration separately from password login?**
   - If yes: Approach D becomes cleaner
   - If no: Local account creation remains possible (minor risk)

2. **What's termix's OIDC config storage format?**
   - If documented: External injection (B) becomes more viable
   - If undocumented: Risk of breakage on upgrades

3. **Would upstream accept a per-user password exception patch?**
   - Need to gauge maintainer receptiveness
   - Alternative: Emergency endpoint might be more palatable

4. **Is there an existing termix "admin CLI" that bypasses the API?**
   - Some apps have CLI tools for emergency admin access
   - Would eliminate need for patching

---

## Next Steps

1. **Test Approach D**: Remove password disable, verify behavior
2. **Check registration settings**: `grep -r "registration" termix` or test in UI
3. **File upstream issue**: Describe the self-jailing problem, propose solutions
4. **Prototype Approach B**: If termix has predictable config storage, test injection

---

## References

- `apps/termix/default.nix` - Current bootstrap implementation
- `apps/pocket-id/default.nix` - OIDC client registration capability
- `common/fort/control-plane.nix` - Provider/need infrastructure
- https://github.com/lukegus/termix - Upstream repository
