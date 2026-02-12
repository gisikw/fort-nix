---
id: fort-oze
status: closed
deps: []
links: []
created: 2026-01-12T06:02:02.706603821Z
type: task
priority: 2
---
# Add wicket repo to forge config

Parent: fort-q3t
Depends: fort-0ij (multi-repo support), fort-d9u (GitHub setup)

## Changes
Add to `clusters/bedlam/manifest.nix` forge.repos:
```nix
"wicket" = {
  mirrors = {
    github = {
      remote = "github.com/gisikw/wicket";
      tokenFile = ./github-mirror-token.age;  # Same token if PAT covers both
    };
  };
};
```

## Deploy
1. Commit and push
2. `just deploy drhorrible`
3. Verify wicket repo created in Forgejo
4. Verify push mirror configured

## Testing
- Push a commit to wicket in Forgejo
- Confirm it appears on GitHub

## Acceptance
- [ ] wicket exists in Forgejo under infra org
- [ ] Push mirror to gisikw/wicket working


