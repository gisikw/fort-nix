---
id: fort-d9u
status: closed
deps: []
links: []
created: 2026-01-12T06:01:34.218728331Z
type: task
priority: 2
---
# GitHub: Create wicket repo and update PAT

Parent: fort-q3t

## Manual steps (user)
1. Create `gisikw/wicket` repo on GitHub (can be empty/private)
2. Update the GitHub PAT used for fort-nix mirroring to also have access to wicket
   - Or create a new PAT with access to both repos
   - Needs `Contents: Read and write` permission on both repos

## Notes
- Current token is at `clusters/bedlam/github-mirror-token.age`
- If creating new token, will need to re-encrypt with agenix
- Could use a single token for all mirrors, or per-repo tokens (single is simpler)

## Acceptance
- [ ] wicket repo exists on GitHub
- [ ] PAT has push access to both fort-nix and wicket


