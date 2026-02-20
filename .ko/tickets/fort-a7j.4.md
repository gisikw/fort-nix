---
id: fort-a7j.4
status: closed
deps: [fort-a7j.3]
links: []
created: 2026-01-10T03:34:09.602737443Z
type: task
priority: 2
parent: fort-a7j
---
# Add vdirsyncer + khal to dev-sandbox

**Goal:** Make vdirsyncer and khal available in the dev user's PATH on ratched.

**Implementation:**
1. Add to `aspects/dev-sandbox/default.nix` devTools list:
   ```nix
   devTools = with pkgs; [
     # ... existing tools ...
     vdirsyncer  # Calendar sync daemon
     khal        # CLI calendar interface
   ];
   ```

2. Create vdirsyncer config directory:
   ```nix
   systemd.tmpfiles.rules = [
     "d /home/dev/.config/vdirsyncer 0700 dev users -"
     "d /home/dev/.local/share/vdirsyncer 0700 dev users -"  # Local calendar storage
   ];
   ```

3. Template vdirsyncer config that points to:
   - Token file from OAuth service: `/var/lib/vdirsyncer/token`
   - Local storage: `/home/dev/.local/share/vdirsyncer/`
   - Multiple calendars (primary + team calendars)

**khal config:**
- Point to the local vdirsyncer storage directory
- Configure default calendar for new events

**Testing:**
```bash
ssh dev@ratched
which vdirsyncer khal
khal list  # Should show synced events
khal new "Test event" tomorrow 10:00-11:00
```

**Depends on:** fort-a7j.3 (OAuth service for token acquisition)


