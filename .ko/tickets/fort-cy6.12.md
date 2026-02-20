---
id: fort-cy6.12
status: closed
deps: [fort-cy6.10, fort-cy6.11]
links: []
created: 2025-12-27T23:55:35.35082255Z
type: task
priority: 2
parent: fort-cy6
---
# Test binary cache flow

Verify the binary cache is working correctly before enabling GitOps.

## Context
Before hosts auto-deploy via comin, we need to confirm:
1. CI builds push to cache
2. Hosts can substitute from cache
3. Cache hits are logged/observable

## Test Cases

### Test 1: CI pushes to cache
1. Push a change to main
2. Watch release workflow
3. Verify build step completes
4. Check Attic UI/CLI for new store paths

```bash
attic cache info fort-cache
# Should show increased path count after CI run
```

### Test 2: Host substitutes from cache
On a test host (e.g., ratched):

```bash
# Clear local store of a known-cached path (carefully!)
# Or just try building something that CI already built

# Check substitution
nix build /nix/store/xxx... --dry-run
# Should show "will be fetched from https://cache.fort.gisi.network"

# Actually build
nix build ./path/to/something
# Should download from cache, not build locally
```

### Test 3: Cache miss builds locally
1. Find a derivation that CI didn't build (e.g., different arch)
2. Build on target host
3. Verify it builds locally
4. (Phase 4 will add push-back to cache)

### Test 4: Monitor cache metrics
If Attic exposes metrics:
- Check Prometheus for cache hit/miss rates
- Verify Grafana dashboard shows cache usage

## Acceptance Criteria
- [ ] CI workflow pushes at least one host build to cache
- [ ] At least one host successfully substitutes from cache
- [ ] Cache hit shows in nix logs (--print-build-logs or similar)
- [ ] No errors in Attic service logs

## Dependencies
- fort-cy6.10: Hosts configured with substituters
- fort-cy6.11: CI pushes to cache

## Notes
- This is the gate before Phase 4 (GitOps)
- Document cache hit rates for future reference
- Consider adding cache monitoring to observability stack


