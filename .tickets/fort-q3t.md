---
id: fort-q3t
status: closed
deps: []
links: []
created: 2026-01-12T06:01:19.903869792Z
type: task
priority: 2
---
# Multi-repo forge support + wicket mirror

## Goal
Extend the forge configuration to support multiple repos with push mirrors, then use it to add the `wicket` repo.

## Context
Currently `forge` config in cluster manifest is single-repo:
```nix
forge = { org = "infra"; repo = "fort-nix"; mirrors = {...}; };
```

Need to support:
```nix
forge = {
  org = "infra";
  repos = {
    "fort-nix" = { mirrors = { github = {...}; }; };
    "wicket" = { mirrors = { github = {...}; }; };
  };
};
```

## Architecture decision
Keep in cluster manifest for now. Moving to `fort.cluster.forge` mkOption would be cleaner but is a bigger refactor - not worth it for 2 repos. Revisit if we hit 5+.

## Acceptance criteria
- [ ] wicket repo exists in Forgejo under infra org
- [ ] Push mirror to gisikw/wicket works
- [ ] Existing fort-nix mirror still works
- [ ] Bootstrap is idempotent (re-running doesn't break anything)


