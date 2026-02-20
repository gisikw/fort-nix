---
id: fort-cy6.3
status: closed
deps: [fort-cy6.2]
links: []
created: 2025-12-27T23:49:47.492597329Z
type: task
priority: 2
parent: fort-cy6
---
# Mirror fort-nix repo to Forgejo

Set up fort-nix repository in Forgejo, either as a mirror of the existing remote or as the new primary.

## Context
fort-nix currently lives on an external git remote. We need it in Forgejo to enable CI/CD via Forgejo Actions.

## Options

### Option A: Mirror (recommended for transition)
- Create repo in Forgejo
- Set up as mirror of existing remote
- Keeps external remote as source of truth during transition
- Forgejo Actions can run on push events

### Option B: Primary (eventual goal)
- Create repo in Forgejo as primary
- Update all developers' remotes
- External remote becomes backup/mirror

## Implementation

### Create repository
Via Forgejo web UI or API:
- Organization: `infra` (create if needed)
- Repository: `fort-nix`
- Visibility: Private (VPN-only access anyway)

### Configure as mirror (Option A)
```bash
# In Forgejo admin: Settings → Mirror → Add mirror
# Source: existing git remote URL
# Sync interval: e.g., every 10 minutes
```

### Or configure as primary (Option B)
```bash
git remote set-url origin https://git.gisi.network/infra/fort-nix.git
# Or add as additional remote during transition:
git remote add forgejo https://git.gisi.network/infra/fort-nix.git
```

### Authentication
- Push access requires authentication
- Options: SSH keys, personal access tokens, or OIDC-integrated git credential helper

## Acceptance Criteria
- [ ] fort-nix repo exists in Forgejo
- [ ] Repository contains current main branch
- [ ] Can push to Forgejo (at least from laptop/ratched)

## Dependencies
- fort-cy6.2: SSO should be configured so users can authenticate

## Notes
- Consider setting up a deploy key for CI operations
- Branch protection rules can be configured later

Labels: [forgejo phase-1]


