---
id: fort-e2w
status: in_progress
deps: []
links: []
created: 2026-01-03T15:33:54.357573256Z
type: epic
priority: 2
---
# Design robust cluster backup solution

## Goal

Design and implement a robust backup solution for the cluster that ensures critical data survives host failures, accidental deletion, and other data loss scenarios.

## Context

- Hosts with impermanence persist `/var/lib` to `/persist/system/var/lib`
- Services like Outline store data in PostgreSQL and local filesystem
- Recent data loss incident (fort-8i4) highlights the need for offsite/redundant backups
- Control plane design (docs/control-plane-design.md) mentions `backup-accept` capability for NAS

## Scope

### Data to backup
- PostgreSQL databases (outline, pocket-id, forgejo, etc.)
- Service state directories (`/var/lib/<service>/`)
- Secrets (already encrypted with agenix, but should be backed up)
- Configuration state (git repo is already backed up via GitHub mirror)

### Hosts with critical data
- **drhorrible** (forge): forgejo, pocket-id, OIDC state
- **q**: outline, actualbudget, vikunja, *arr stack configs
- **ursula**: home assistant state, zigbee2mqtt
- **raishan** (beacon): headscale state

## Design considerations

1. **Backup tool**: restic vs borg vs custom
   - restic: Good dedup, encryption, S3/B2 backends
   - borg: Battle-tested, excellent dedup
   - Custom: Agent-based using `backup-accept` capability

2. **Backup destination**
   - Offsite cloud (B2, S3, Wasabi)
   - Local NAS (if available)
   - Cross-host (backup to another cluster host)

3. **Integration with agent architecture**
   - `backup-accept` capability on NAS/backup host
   - Hosts push backups via agent call
   - Or: backup host pulls from other hosts

4. **Scheduling**
   - PostgreSQL: pg_dump on schedule, ship to backup
   - Filesystem: incremental snapshots
   - Retention policy

5. **Recovery testing**
   - How do we verify backups are usable?
   - Periodic restore tests?

## Deliverables

1. Design doc with chosen approach
2. Backup aspect or role for hosts
3. Recovery runbook
4. Monitoring/alerting for backup failures

## References

- docs/control-plane-design.md (mentions backup-accept capability)
- fort-8i4 (Outline data loss investigation)


