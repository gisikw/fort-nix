---
id: fort-8i4
status: closed
deps: []
links: []
created: 2026-01-03T15:33:11.702049834Z
type: task
priority: 2
---
# Investigate Outline data loss on q

## Problem

User's Outline data appears to be missing. Initial investigation found:
- `/var/lib/outline/` has older data
- `/var/lib/postgresql/` is quite recent (suggests possible reset)
- Persistence config in `common/host.nix` looks correct (`/var/lib` → `/persist/system/var/lib`)

## Possible causes to investigate

1. **PostgreSQL data reset** - Version upgrade, schema migration, or other reset
2. **OIDC identity mismatch** - Recent OIDC changes may have caused Outline to treat user as a new account (different team/workspace)
3. **Persistence gap** - Brief period where `/var/lib` wasn't properly bound to persistent storage
4. **Host reprovisioning** - If `q` was reinstalled at some point

## Investigation steps

1. Check postgres data timestamps and contents
2. Review Outline logs for auth/user creation events
3. Check if there are multiple teams/workspaces in the database
4. Review git history for OIDC-related changes around the time data was last seen
5. Verify impermanence bind mounts are working correctly

## Context

- Host: q (beelink profile, impermanent=true)
- Outline added in commit 1908fb5 (Nov 2025)
- Recent OIDC work on pocket-id may be relevant


