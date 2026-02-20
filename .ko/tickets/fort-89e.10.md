---
id: fort-89e.10
status: closed
deps: [fort-89e.9, fort-89e.7]
links: []
created: 2025-12-30T22:03:38.868657192Z
type: task
priority: 2
parent: fort-89e
---
# Migrate dev-sandbox git access to control plane

Switch git token distribution from timer-push to agent-pull:

1. Add fort.needs.git-token to dev-sandbox aspect
2. Store token at /var/lib/fort-git/forge-token (existing location)
3. Verify git operations work
4. Remove forgejo-deploy-token-sync timer from forgejo app

Should be straightforward - same pattern as cert migration.

## Acceptance Criteria

- dev-sandbox hosts receive git tokens via control plane
- Git clone/push works with new token delivery
- forgejo-deploy-token-sync removed


