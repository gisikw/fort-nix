---
id: fort-cy6.14
status: closed
deps: [fort-cy6.13]
links: []
created: 2025-12-27T23:56:30.002650682Z
type: task
priority: 2
parent: fort-cy6
---
# Deploy comin to joker (test host)

Deploy comin to ratched as the first GitOps-enabled host.

## Context
Ratched is the dev sandbox - low risk, easy to recover if something breaks. It's the ideal first host for GitOps.

## Implementation

### Update ratched manifest
Edit `clusters/bedlam/hosts/ratched/manifest.nix`:

```nix
{
  hostName = "ratched";
  deviceUuid = "...";
  
  roles = [];
  
  apps = [];
  
  aspects = [
    "mesh"
    "observable"
    "dev-sandbox"
    "gitops"  # Add this
  ];
}
```

### Initial deploy via deploy-rs
The first deploy must be via deploy-rs (chicken-and-egg: comin isn't installed yet):

```bash
just deploy ratched
```

### Verify comin is running
After deploy:

```bash
ssh root@ratched.fort.gisi.network

# Check service status
systemctl status comin

# Check logs
journalctl -u comin -f

# Comin should be polling and showing "no changes" or similar
```

### Test a change
1. Make a small change to ratched's config (e.g., add a comment)
2. Push to main
3. Wait for CI to update release branch
4. Watch comin logs on ratched
5. Verify the change is applied

## Acceptance Criteria
- [ ] Comin service running on ratched
- [ ] Comin successfully polls Forgejo
- [ ] Comin detects and applies a test change
- [ ] No manual intervention needed for the test change

## Dependencies
- fort-cy6.13: Comin aspect must be created

## Notes
- If comin breaks ratched, we can still SSH in and fix manually
- Or use deploy-rs as fallback
- This validates the entire pipeline before rolling out to other hosts


