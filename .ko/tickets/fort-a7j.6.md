---
id: fort-a7j.6
status: closed
deps: [fort-a7j.5]
links: []
created: 2026-01-10T03:36:05.987763807Z
type: task
priority: 2
parent: fort-a7j
---
# Add sync freshness indicator for Exo

**Goal:** Give Exo a way to check if calendar data is fresh before making decisions.

**Options (pick one during implementation):**

1. **File mtime approach** (simplest):
   - Check mtime of `/home/dev/.local/share/vdirsyncer/.sync_complete`
   - Touch this file at end of successful sync
   - Exo runs: `stat -c %Y ~/.local/share/vdirsyncer/.sync_complete` and compares to now

2. **Systemd status approach**:
   - `systemctl show vdirsyncer-sync --property=ActiveExitTimestamp`
   - Parse the timestamp, compare to now
   - Also check `ExecMainStatus=0` for success

3. **Wrapper script**:
   ```bash
   # /home/dev/.local/bin/calendar-sync-status
   last_sync=$(stat -c %Y ~/.local/share/vdirsyncer/.sync_complete 2>/dev/null || echo 0)
   now=$(date +%s)
   age=$((now - last_sync))
   if [ $age -lt 1800 ]; then  # 30 min threshold
     echo "fresh ($age seconds ago)"
   else
     echo "stale ($age seconds ago)"
   fi
   ```

**Integration with khal:**
- Exo can then confidently use `khal list today tomorrow` knowing data is fresh
- Or trigger manual sync: `vdirsyncer sync` if stale

**Depends on:** fort-a7j.5 (sync timer running)


