---
id: fort-a7j.3
status: closed
deps: [fort-a7j.2]
links: []
created: 2026-01-10T03:33:51.83922333Z
type: task
priority: 2
parent: fort-a7j
---
# Add vdirsyncer OAuth token service

**Goal:** Expose vdirsyncer's built-in OAuth handler as a gatekeeper-protected public service.

**Implementation:**
1. Create `apps/vdirsyncer-auth/default.nix`
2. Systemd service that runs vdirsyncer in OAuth mode (or a thin wrapper that triggers `vdirsyncer discover`)
3. Declare in `fort.cluster.services`:
   ```nix
   fort.cluster.services = [{
     name = "vdirsyncer-auth";
     port = 8088;  # vdirsyncer's default OAuth callback port
     visibility = "public";  # Accessible from work laptop
     sso = {
       mode = "gatekeeper";  # Login required, no identity passed
       groups = [ "admins" ];  # Restrict to Kevin
     };
   }];
   ```
4. Store OAuth token in `/var/lib/vdirsyncer/token` (readable by vdirsyncer-sync timer)

**Secrets needed:**
- `vdirsyncer-oauth-client.age`: Contains `client_id` and `client_secret` from Google Cloud

**Notes:**
- Service can remain running for token refresh, or be disabled after initial auth
- The port 8088 is hardcoded in vdirsyncer's google.py - need to verify this works with nginx proxy
- May need to patch redirect URI handling if vdirsyncer expects localhost

**Depends on:** fort-a7j.2 (OAuth credentials created)


