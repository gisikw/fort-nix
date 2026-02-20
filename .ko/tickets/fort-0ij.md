---
id: fort-0ij
status: closed
deps: []
links: []
created: 2026-01-12T06:01:50.208968671Z
type: task
priority: 2
---
# Refactor forge config to support multiple repos

Parent: fort-q3t
Depends: fort-d9u (need token ready before testing)

## Schema change
In `clusters/bedlam/manifest.nix`, change from:
```nix
forge = {
  org = "infra";
  repo = "fort-nix";
  mirrors = { github = {...}; };
};
```

To:
```nix
forge = {
  org = "infra";
  repos = {
    "fort-nix" = {
      mirrors = { github = { remote = "github.com/gisikw/fort-nix"; tokenFile = ./github-mirror-token.age; }; };
    };
  };
};
```

## Bootstrap refactor
In `apps/forgejo/default.nix`:
1. Update `forgeConfig` references to use new schema
2. Change `FORGEJO_REPO` scalar to iterate over `forgeConfig.repos`
3. Per-repo: create repo, configure mirrors
4. Keep org creation as-is (still single org)
5. Keep token generation as-is (not per-repo)

## Key changes in bootstrap script
- `for repo in $(echo "$REPOS" | jq -r 'keys[]'); do`
- Each repo gets its own mirror config
- Existing fort-nix behavior preserved

## Testing
- `nix flake check` passes
- Deploy to drhorrible
- Verify fort-nix mirror still works (push a commit, check GitHub)

## Acceptance
- [ ] Schema updated
- [ ] Bootstrap iterates over repos
- [ ] fort-nix mirror still works after deploy


