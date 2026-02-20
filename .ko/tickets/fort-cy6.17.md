---
id: fort-cy6.17
status: closed
deps: [fort-cy6.16]
links: []
created: 2025-12-27T23:59:26.664584628Z
type: task
priority: 2
parent: fort-cy6
---
# Roll out comin to remaining hosts

Enable GitOps on remaining hosts (except forge).

## Context
After validating GitOps on ratched, roll out to other hosts incrementally.

## Hosts to Enable

Enable comin on (in suggested order):
1. **joker** - minimal node, low risk
2. **ursula** - media server
3. **lordhenry** - LLM stack
4. **minos** - IoT hub (more complex, test carefully)
5. **q** - ingest machine (many services)
6. **raishan** - beacon (public-facing, do last among these)

## DO NOT Enable
- **drhorrible (forge)** - stays on manual deploy-rs (critical infrastructure)

## Rollout Process

For each host:

1. **Update manifest**
   ```nix
   aspects = [
     # ... existing aspects ...
     "gitops"
   ];
   ```

2. **Deploy via deploy-rs** (first time)
   ```bash
   just deploy <hostname>
   ```

3. **Verify comin running**
   ```bash
   ssh root@<hostname>.fort.gisi.network
   systemctl status comin
   ```

4. **Test a change**
   Push a small change, verify it propagates

5. **Monitor for issues**
   Check logs, verify services healthy

### Rollback Plan
If a host has issues:
1. SSH in (should still work)
2. `systemctl stop comin` to prevent further changes
3. Fix via `nixos-rebuild switch` or deploy-rs
4. Investigate root cause before re-enabling

## Acceptance Criteria
- [ ] All hosts (except forge) running comin
- [ ] All hosts successfully deploying from release branch
- [ ] No manual intervention needed for normal changes
- [ ] Forge confirmed to still work with deploy-rs

## Dependencies
- fort-cy6.16: E2E test must pass first

## Notes
- Take it slow - one host at a time
- Have a rollback plan ready
- Monitor for a few days before considering complete
- Update documentation with new deployment workflow


