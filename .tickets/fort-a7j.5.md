---
id: fort-a7j.5
status: closed
deps: [fort-a7j.4]
links: []
created: 2026-01-10T03:34:24.888605414Z
type: task
priority: 2
parent: fort-a7j
---
# Add vdirsyncer-sync systemd timer

**Goal:** Periodic bidirectional sync between Google Calendar and local storage.

**Implementation:**
Add to dev-sandbox aspect (or as a separate vdirsyncer aspect):

```nix
systemd.timers."vdirsyncer-sync" = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnBootSec = "2m";           # First sync 2min after boot
    OnUnitActiveSec = "15m";    # Then every 15 minutes per epic spec
  };
};

systemd.services."vdirsyncer-sync" = {
  description = "Sync calendars with Google";
  path = with pkgs; [ vdirsyncer ];
  serviceConfig = {
    Type = "oneshot";
    User = "dev";
    Group = "users";
    ExecStart = "${pkgs.vdirsyncer}/bin/vdirsyncer sync";
    StandardOutput = "journal";
    StandardError = "journal";
  };
  environment = {
    HOME = "/home/dev";
  };
};
```

**Monitoring:**
```bash
systemctl list-timers vdirsyncer-sync
journalctl -u vdirsyncer-sync -n 20
```

**Depends on:** fort-a7j.4 (vdirsyncer + khal installed and configured)


