---
id: fort-cy6.16
status: closed
deps: [fort-cy6.14, fort-cy6.15]
links: []
created: 2025-12-27T23:59:08.283025585Z
type: task
priority: 2
parent: fort-cy6
---
# Test GitOps end-to-end flow

Comprehensive test of the complete GitOps pipeline before rolling out to more hosts.

## Context
Before enabling comin on production hosts, verify the entire flow works:
1. Push to main
2. CI builds + re-keys → release branch
3. Comin pulls release on ratched
4. Ratched deploys and pushes to cache

## Test Scenario

### Make a visible change
Add something observable to ratched's config:

```nix
# In ratched's config, add:
environment.etc."gitops-test".text = "deployed at: ${builtins.currentTime}";
# Or simpler: add a systemd service, a package, etc.
```

### Execute the test

1. **Commit and push to main**
   ```bash
   git add .
   git commit -m "Test GitOps flow"
   git push origin main
   ```

2. **Watch CI** (Forgejo Actions)
   - Flake check passes
   - Build step runs (may use cache)
   - Re-key step runs
   - Release branch updated

3. **Watch comin on ratched**
   ```bash
   ssh root@ratched.fort.gisi.network
   journalctl -u comin -f
   # Should see: pull, evaluate, build, activate
   ```

4. **Verify change applied**
   ```bash
   cat /etc/gitops-test
   # Should show the file we added
   ```

5. **Verify cache populated**
   ```bash
   attic cache info fort-cache
   # Should show ratched's paths
   ```

### Timing
Note the time from push to activation. This is your deployment latency:
- CI time: ~X minutes
- Comin poll interval: up to 60s
- Build time: depends on cache hits
- Total: ~Y minutes

## Failure Scenarios to Test

### Test: What if CI fails?
- Push a change that breaks flake check
- Verify release branch is NOT updated
- Verify ratched stays on previous config

### Test: What if comin build fails?
- Push a change that evaluates but fails to build
- Verify ratched stays on previous config
- Check comin logs for error

### Test: Manual rollback
- If needed, how to manually fix ratched?
- `nixos-rebuild switch` or deploy-rs should still work

## Acceptance Criteria
- [ ] Change flows from push → ratched without manual intervention
- [ ] Deployment time is acceptable (< 10 minutes?)
- [ ] Failed changes don't break ratched
- [ ] Manual recovery path confirmed working

## Dependencies
- fort-cy6.14: Comin deployed to ratched
- fort-cy6.15: Post-build hook configured

## Notes
- This is the gate before production rollout
- Document any issues for future reference
- Consider adding alerting for comin failures


