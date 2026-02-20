---
id: fort-cy6.18
status: closed
deps: [fort-cy6.17]
links: []
created: 2025-12-27T23:59:55.004948365Z
type: task
priority: 2
parent: fort-cy6
---
# Grant Claude Code push access to Forgejo

Configure Claude Code on ratched to push to Forgejo without exposing sensitive credentials.

## Context
The goal of this entire initiative: Claude Code can trigger deployments by pushing to git, without having SSH access to production hosts or the ability to decrypt production secrets.

## Implementation

### Authentication Options

1. **Personal Access Token**
   - Create a Forgejo PAT for "claude-code" user
   - Store on ratched (can be in plain file - it only grants git push)
   - Configure git credential helper

2. **SSH Deploy Key**
   - Generate SSH key on ratched
   - Add public key to Forgejo as deploy key with write access
   - Configure git to use this key

3. **OIDC-based auth** (if supported)
   - More complex but more secure

### Recommended: Personal Access Token

On ratched:
```bash
# Store token (created via Forgejo UI)
echo "token_here" > /persist/system/home/dev/.forgejo-token
chmod 600 /persist/system/home/dev/.forgejo-token

# Configure git
git config --global credential.helper store
# Or use a credential helper that reads from file
```

In NixOS config:
```nix
# Ensure git is configured for the dev user
home-manager.users.dev = {
  programs.git = {
    enable = true;
    extraConfig = {
      credential.helper = "store --file=/persist/system/home/dev/.forgejo-token";
    };
  };
};
```

### Create Forgejo User
- Create "claude-code" user in Forgejo
- Grant write access to fort-nix repo
- Generate PAT with repo write scope

### Permissions Audit
Verify Claude Code on ratched has:
- [x] Push access to Forgejo (this ticket)
- [x] Editor key for main branch secrets
- [ ] NO SSH access to other hosts
- [ ] NO access to production secrets (only editor-keyed)
- [ ] NO access to FORGE_AGE_KEY

## Acceptance Criteria
- [ ] Claude Code can `git push` to Forgejo
- [ ] Push triggers CI workflow
- [ ] No additional credentials exposed to Claude Code

## Dependencies
- fort-cy6.17: GitOps must be working first

## Notes
- This is the final piece that enables autonomous Claude Code deployments
- Token should be rotatable without system changes
- Consider audit logging of pushes


