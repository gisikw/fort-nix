---
id: fort-cy6.8
status: closed
deps: [fort-cy6.7]
links: []
created: 2025-12-27T23:53:26.367461113Z
type: task
priority: 2
parent: fort-cy6
---
# Test CI pipeline end-to-end

Verify the complete CI pipeline works correctly before proceeding to cache and GitOps phases.

## Context
Before adding binary caching and comin, we need to verify:
1. Check workflow runs on PRs
2. Release workflow creates properly-keyed release branch
3. Secrets are correctly re-keyed for each host

## Test Cases

### Test 1: Check workflow on PR
1. Create a branch with a minor change
2. Open PR against main
3. Verify check workflow triggers and passes
4. Verify checks block merge if they fail

### Test 2: Release workflow on merge
1. Merge the PR to main
2. Verify release workflow triggers
3. Verify release branch is created/updated

### Test 3: Secret re-keying verification
For each host, verify the secrets in release branch are correctly keyed:

```bash
# Checkout release branch
git checkout release

# For a test host (e.g., ratched), try decrypting a secret
# This should FAIL on main branch (editor keys only)
# This should SUCCEED on release branch (host key)

# On the target host, or with the host's private key:
age -d -i /path/to/host/key aspects/mesh/auth-key.age
```

### Test 4: Editor access on main
Verify editors can still decrypt on main:
```bash
git checkout main
age -d -i ~/.ssh/id_ed25519 aspects/mesh/auth-key.age  # Should work
```

### Test 5: Host cannot decrypt main
Verify hosts cannot decrypt main branch secrets:
```bash
git checkout main
age -d -i /path/to/host/key aspects/mesh/auth-key.age  # Should FAIL
```

## Acceptance Criteria
- [ ] Check workflow passes on current main
- [ ] Release branch exists after push to main
- [ ] At least one host's secrets verified to be correctly keyed on release
- [ ] Editors confirmed able to decrypt main branch secrets
- [ ] Hosts confirmed unable to decrypt main branch secrets

## Dependencies
- fort-cy6.7: Release workflow must be implemented

## Notes
- Document any issues found for future reference
- This is a gate before proceeding to Phase 3
- Consider automating these tests as part of the pipeline


