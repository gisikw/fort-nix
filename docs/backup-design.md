# Backup System Design Proposal

Design options for cluster-wide backup following 3-2-1 principles.

**Status**: Proposal - awaiting review

---

## 1. Goals & Constraints

### Must Have
- **3-2-1 compliance**: 3 copies, 2 media types, 1 offsite
- **Encryption at rest**: All offsite destinations assumed compromised
- **Multi-host support**: Backup all hosts with persistent data from one orchestration point
- **Declarative configuration**: Backup schedules and retention defined in Nix
- **Automated verification**: Know when backups fail

### Nice to Have
- Peer-to-peer backup exchange (mutual server leasing with family/friends)
- Minimal cloud spend (cloud as backup-of-last-resort, not primary)
- Dedupe across hosts (shared data backed up once)
- Point-in-time recovery (multiple snapshots, not just latest)

### Constraints
- Hosts use impermanence; persistent data lives in `/var/lib` (via `/persist/system/var/lib`)
- Git repo already mirrored to GitHub (config is covered)
- Agent architecture exists for inter-host coordination
- No dedicated NAS currently; ursula has ZFS but is itself a backup target

---

## 2. Data Inventory

| Host | Critical Data | Approx Size | Notes |
|------|--------------|-------------|-------|
| **drhorrible** | forgejo repos/DB, pocket-id DB, OIDC state | ~5GB | Identity is crown jewels |
| **q** | outline DB, actualbudget, vikunja, *arr configs | ~10GB | Excludes media (too large) |
| **ursula** | jellyfin DB, audiobookshelf, calibre-web | ~2GB | Media itself is replaceable |
| **raishan** | headscale DB | ~100MB | Mesh coordination state |
| **joker/lordhenry/minos** | Minimal | <100MB | Mostly stateless |

**Total critical data**: ~20GB compressed (estimated)

### What NOT to back up
- Media files (movies, music, audiobooks) - too large, replaceable from source
- Nix store - reproducible from config
- Container images - pulled from registries
- Logs - ephemeral by design

---

## 3. Backup Tool Comparison

### Option A: Restic

**Pros:**
- Native S3/B2/Wasabi support (no rclone needed)
- REST server for self-hosted central hub with append-only mode
- Good NixOS packaging and `services.restic.backups` module
- Deduplication within repo
- Cross-platform (Go binary)

**Cons:**
- No compression until recently (restic 0.16+)
- Memory usage higher than Borg for large repos
- No native SSH-only mode (needs REST server or cloud backend)

**Best for**: Cloud backends, simple self-hosted REST server

### Option B: BorgBackup

**Pros:**
- Battle-tested, excellent compression + deduplication
- Lower memory footprint
- SSH-native (no extra server component)
- Mature NixOS module

**Cons:**
- Cloud support requires rclone/borgmatic wrapper
- Borg 2.0 not yet in nixpkgs stable
- Harder to set up append-only mode

**Best for**: SSH-accessible backup targets, maximum efficiency

### Option C: Kopia

**Pros:**
- Modern design, fast, good UI
- Built-in cloud and local support
- Repository server with access control

**Cons:**
- Younger project, less battle-tested
- NixOS packaging less mature

### Option D: Custom (agent-based tarball transfer)

**Pros:**
- Full control, fits existing agent architecture
- No new dependencies

**Cons:**
- No deduplication
- No incremental backups without significant work
- Reinventing the wheel

### Recommendation

**Restic** offers the best balance for our use case:
- Native cloud backends for 3-2-1 offsite copy
- REST server for self-hosted hub with append-only security
- Declarative NixOS module
- Can layer agent orchestration on top for multi-host coordination

---

## 4. Architecture Options

### Option 1: Centralized Hub (Recommended)

```
                    ┌─────────────────┐
                    │  Backup Hub     │
                    │  (new host or   │
                    │  ursula w/ ZFS) │
                    │                 │
                    │  restic REST    │
                    │  server         │
                    └────────┬────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
         ▼                   ▼                   ▼
   ┌──────────┐       ┌──────────┐       ┌──────────┐
   │drhorrible│       │    q     │       │  ursula  │
   │          │       │          │       │          │
   │ restic   │       │ restic   │       │ restic   │
   │ push     │       │ push     │       │ push     │
   └──────────┘       └──────────┘       └──────────┘

   Hub syncs to:
   ├── Cloud (B2/Wasabi) - offsite copy
   └── Peer server (brother's) - encrypted, offsite
```

**How it works:**
1. Each host runs restic on a schedule, pushing to hub's REST server
2. Hub stores primary backup repo on local storage (copy 1)
3. Hub syncs repo to cloud storage nightly (copy 2, offsite)
4. Hub syncs to peer server (copy 3, offsite, different provider)

**Pros:**
- Simple per-host config (just push to hub URL)
- Deduplication across all hosts (shared repo)
- Append-only mode on hub protects against ransomware
- Hub handles offsite sync logic centrally

**Cons:**
- Single point of failure (hub down = no backups)
- Needs hub to be reliable (could be ursula with ZFS, or dedicated device)

### Option 2: Fully Distributed (P2P)

```
   drhorrible ◄────► q ◄────► ursula
        │                        │
        └──────► cloud ◄─────────┘
```

**How it works:**
1. Each host backs up to N other hosts directly
2. Each host also backs up to cloud
3. No central coordinator

**Pros:**
- No single point of failure
- Survives loss of any single host

**Cons:**
- More complex coordination
- N² network connections
- Harder to reason about coverage

### Option 3: Cloud-Primary with Local Cache

```
   Each host → Cloud (primary)
             → Local cache (fast restore)
```

**How it works:**
1. Each host backs up directly to cloud (B2/Wasabi)
2. Local "cache" copy kept for fast restores
3. No self-hosted infrastructure

**Pros:**
- Simplest to operate
- Cloud handles durability

**Cons:**
- Ongoing cloud costs (though minimal for ~20GB)
- Restore speed depends on internet
- No local-first resilience

### Recommendation

**Option 1 (Centralized Hub)** with ursula as the hub:
- ursula already has ZFS for local redundancy
- REST server in append-only mode
- Hub handles cloud sync
- Fits 3-2-1: local (hub), cloud, peer

---

## 5. Offsite Destinations

### 5.1 Cloud (Backup of Last Resort)

| Provider | Cost (20GB) | Notes |
|----------|-------------|-------|
| Backblaze B2 | ~$0.10/mo | Restic native support, egress $0.01/GB |
| Wasabi | ~$1.40/mo | No egress fees, 1TB minimum billing |
| Cloudflare R2 | Free (<10GB) | No egress, S3-compatible |

**Recommendation**: Backblaze B2 for cost efficiency, or R2 if under 10GB.

All cloud storage receives already-encrypted restic repo data. Even if provider is compromised, data is unreadable without the repo password.

### 5.2 Peer Exchange (Brother's Server)

**Concept**: Mutual backup arrangement where you each host encrypted backups for the other.

**Implementation options:**

**A. Restic REST server on peer**
- Peer runs `rest-server --append-only --private-repos`
- You push encrypted restic repo over HTTPS
- They can't read your data (encrypted with your key)
- They can't delete it (append-only mode)

**B. Restic over SSH (sftp backend)**
- Peer provides SSH access to a directory
- You push encrypted repo via sftp
- Simpler setup, no REST server needed

**C. Rclone to peer's storage**
- If peer runs any S3-compatible storage (MinIO, etc.)
- Restic → rclone → peer's S3

**Trust model:**
- Peer has physical access to encrypted blobs
- Cannot read content (AES-256 encryption, your key)
- In append-only mode, cannot delete your backups
- You should verify periodically that backups exist

**Recommendation**: REST server over WireGuard/Tailscale tunnel. Simple, secure, append-only.

---

## 6. Integration with Fort Architecture

### 6.1 New Aspect: `backup-client`

```nix
# aspects/backup-client/default.nix
{
  # Install restic
  environment.systemPackages = [ pkgs.restic ];

  # Declarative backup jobs
  services.restic.backups.system = {
    repository = "rest:https://backup.fort.${domain}/";
    passwordFile = config.age.secrets.restic-password.path;
    paths = [ "/var/lib" ];
    exclude = [
      "/var/lib/docker"
      "/var/lib/containers"
      "*.log"
    ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
    };
  };

  # Backup for PostgreSQL (if present)
  services.restic.backups.postgres = lib.mkIf config.services.postgresql.enable {
    repository = "rest:https://backup.fort.${domain}/";
    passwordFile = config.age.secrets.restic-password.path;
    backupPrepareCommand = ''
      ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql}/bin/pg_dumpall > /tmp/postgres-backup.sql
    '';
    paths = [ "/tmp/postgres-backup.sql" ];
    backupCleanupCommand = "rm -f /tmp/postgres-backup.sql";
    timerConfig.OnCalendar = "daily";
  };
}
```

### 6.2 New Role or App: `backup-hub`

For the host that receives and syncs backups:

```nix
# apps/backup-hub/default.nix (or role)
{
  # Restic REST server
  services.restic.server = {
    enable = true;
    appendOnly = true;
    privateRepos = true;
    dataDir = "/var/lib/restic-repos";
    listenAddress = "127.0.0.1:8000";
  };

  # Expose via nginx (internal only)
  fortCluster.exposedServices = [{
    name = "backup";
    port = 8000;
    visibility = "vpn";  # Only mesh-accessible
    sso.mode = "none";   # Restic handles auth
  }];

  # Sync to cloud
  systemd.services.backup-cloud-sync = {
    script = ''
      ${pkgs.rclone}/bin/rclone sync /var/lib/restic-repos b2:fort-backups
    '';
    serviceConfig.Type = "oneshot";
  };
  systemd.timers.backup-cloud-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "02:00";  # 2 AM
  };

  # Sync to peer
  systemd.services.backup-peer-sync = {
    script = ''
      ${pkgs.rclone}/bin/rclone sync /var/lib/restic-repos peer:fort-backups
    '';
    serviceConfig.Type = "oneshot";
  };
  systemd.timers.backup-peer-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "03:00";
  };
}
```

### 6.3 Agent Capabilities (Optional Enhancement)

For visibility/control via agent API:

| Capability | Purpose |
|------------|---------|
| `backup-status` | Return last backup time, size, success/failure per host |
| `backup-trigger` | Manually trigger backup from remote |
| `backup-list` | List available snapshots |

These could live on the backup hub and be called from dev-sandbox for operational visibility.

---

## 7. Monitoring & Alerting

### Backup Health Checks

```nix
# In backup-hub
systemd.services.backup-monitor = {
  script = ''
    # Check each host's last backup
    for host in drhorrible q ursula raishan; do
      last_backup=$(restic -r /var/lib/restic-repos/$host snapshots --latest 1 --json | jq -r '.[0].time')
      # Alert if > 48 hours old
      ...
    done
  '';
  serviceConfig.Type = "oneshot";
};
systemd.timers.backup-monitor = {
  wantedBy = [ "timers.target" ];
  timerConfig.OnCalendar = "hourly";
};
```

### Integration with fort-observability

- Prometheus metrics for backup age, size, duration
- AlertManager rules for stale backups
- Grafana dashboard showing backup health

---

## 8. Recovery Procedures

### Full Host Recovery

```bash
# 1. Boot new NixOS, mount disks
# 2. Install restic
nix-shell -p restic

# 3. Restore from backup
export RESTIC_REPOSITORY="rest:https://backup.fort.${domain}/"
export RESTIC_PASSWORD_FILE=/tmp/restic-password
restic restore latest --target /mnt

# 4. Rebuild NixOS
nixos-install --flake github:user/fort-nix#hostname
```

### Single Service Recovery

```bash
# Restore just outline's data
restic restore latest --target /tmp/restore --include "/var/lib/outline"
systemctl stop outline
cp -a /tmp/restore/var/lib/outline/* /var/lib/outline/
systemctl start outline
```

### Periodic Recovery Testing

Automated monthly test restore to a staging VM:
- Spin up ephemeral VM
- Restore from backup
- Run smoke tests
- Alert if tests fail

(This is advanced - implement after basic backup is working)

---

## 9. Implementation Plan

### Phase 1: Foundation
- [ ] Set up restic REST server on ursula
- [ ] Create `backup-client` aspect
- [ ] Add aspect to drhorrible, q, ursula, raishan
- [ ] Create shared restic password secret
- [ ] Verify local backups working

### Phase 2: Offsite - Cloud
- [ ] Set up Backblaze B2 bucket (or R2)
- [ ] Add rclone config to backup hub
- [ ] Configure nightly cloud sync
- [ ] Verify cloud backup integrity

### Phase 3: Offsite - Peer
- [ ] Coordinate with brother on setup
- [ ] Either: they run REST server, or we push via rclone
- [ ] Set up WireGuard tunnel if needed
- [ ] Configure peer sync

### Phase 4: Monitoring
- [ ] Add backup metrics to observability stack
- [ ] Create AlertManager rules
- [ ] Document recovery procedures

### Phase 5: Hardening
- [ ] Implement backup verification tests
- [ ] Add agent capabilities for visibility
- [ ] Consider automated recovery testing

---

## 10. Design Decisions

1. **Hub location**: ursula (has ZFS). Slightly brittle (backs up to itself) but a dedicated NAS box isn't justified yet. Cloud + peer provide offsite redundancy.

2. **Restic auth**: TBD - REST server supports htpasswd. Per-host credentials give better audit trail but add secret management overhead.

3. **Retention policy**: 7 daily, 4 weekly, 6 monthly.

4. **PostgreSQL strategy**: Daily pg_dump. WAL archiving is overkill unless we need point-in-time recovery or zero-downtime snapshots.

5. **Peer server**: Brother runs Ubuntu. We'll need to package/deploy REST server there - could be a simple docker-compose or a lightweight NixOS container.

## 10.1 Data Tiers

| Tier | Examples | Backup? |
|------|----------|---------|
| **Ephemeral** | Nix store, containers, tmpfs root | No - derived from repo |
| **Persisted state** | `/var/lib/*`, dev-sandbox home dirs | Yes - primary backup target |
| **Media** | Movies, music, audiobooks on ursula | No - replaceable from source |

Media backup may become relevant for hard-to-replace content (rare albums, personal recordings) but is out of scope for initial implementation.

---

## 11. Cost Estimate

| Item | Monthly Cost |
|------|--------------|
| Backblaze B2 (20GB storage) | ~$0.10 |
| Backblaze B2 (egress, rare) | ~$0.20 |
| Peer exchange | $0 (mutual) |
| Total | ~$0.30/mo |

Even at 100GB, costs stay under $1/mo with B2.

---

## References

- [Restic Documentation](https://restic.readthedocs.io/)
- [Restic REST Server](https://github.com/restic/rest-server)
- [NixOS Restic Module](https://search.nixos.org/options?query=services.restic)
- [3-2-1 Backup Strategy](https://www.backblaze.com/blog/the-3-2-1-backup-strategy/)
- [Restic vs Borg Comparison](https://ultahost.com/blog/restic-vs-borg/)
- [Backrest Web UI](https://github.com/garethgeorge/backrest)
