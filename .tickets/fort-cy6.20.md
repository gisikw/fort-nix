---
id: fort-cy6.20
status: closed
deps: [fort-cy6.17]
links: []
created: 2025-12-28T00:00:33.63959393Z
type: task
priority: 3
parent: fort-cy6
---
# Verify deploy-rs still works as escape hatch

Confirm deploy-rs remains functional as an escape hatch for manual deployments.

## Context
Even with GitOps, we need deploy-rs to work for:
- Forge (drhorrible) - always manual
- Emergency overrides on any host
- High-risk changes where you want rollback protection

## Verification

### Test on forge
```bash
just deploy drhorrible
```
- Should work as before
- This is the primary deployment method for forge

### Test on a GitOps host
```bash
just deploy ratched
```
- Should still work
- Comin and deploy-rs can coexist
- deploy-rs does immediate push, comin will eventually converge

### Verify rollback still works
1. Deploy a change that breaks SSH (test carefully!)
2. Verify deploy-rs rolls back automatically
3. Host should remain accessible

### Check for conflicts
- Comin polling shouldn't interfere with deploy-rs
- If both try to activate simultaneously, one should win cleanly

## Acceptance Criteria
- [ ] `just deploy drhorrible` works
- [ ] `just deploy <gitops-host>` works
- [ ] No conflicts between comin and deploy-rs
- [ ] Rollback protection functional on deploy-rs deploys

## Dependencies
- fort-cy6.17: GitOps must be rolled out first

## Notes
- deploy-rs uses SSH, comin uses git pull - different mechanisms
- Keep Justfile deploy commands working
- This is insurance against GitOps failures


