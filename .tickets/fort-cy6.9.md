---
id: fort-cy6.9
status: closed
deps: [fort-cy6.8]
links: []
created: 2025-12-27T23:54:07.515511079Z
type: task
priority: 2
parent: fort-cy6
---
# Add Attic binary cache to forge

Deploy Attic binary cache server on drhorrible (forge).

## Status: IN PROGRESS - Deploy pending

### Completed
- [x] Add attic flake input to root flake.nix
- [x] Update all host flakes to follow root/attic
- [x] Update common/host.nix to import atticd NixOS module
- [x] Create apps/attic/default.nix with services.atticd config
- [x] Add attic to forge role
- [x] Generate and encrypt server token secret
- [x] Create bootstrap service for cache/token creation
- [x] Update Justfile template for new hosts
- [x] Document Service Initialization patterns in AGENTS.md
- [x] Fix forgejo binary rename (gitea -> forgejo) broken by nixpkgs update
- [x] Add pkgs.attic-client to attic bootstrap path

### Pending
- [ ] Debug atticd startup failure (exit code 101)
- [ ] Successful deploy to drhorrible
- [ ] Verify cache accessible at cache.gisi.network
- [ ] Test pushing a derivation to cache

### Known Issues
The first deploy attempt failed with:
1. **atticd.service exit 101** - Unknown cause, need to check logs after next deploy
2. **forgejo-bootstrap gitea not found** - Fixed (binary renamed to `forgejo` in nixos-25.11)
3. **Tailscale state corruption** - Side effect of failed deploy, fixed by clearing state

The nixpkgs was also updated from 2025-10-14 to 2025-12-06 as a side effect of adding the attic input (host lock files were fully updated rather than just adding new input).

### Files Changed
- flake.nix, flake.lock (attic input)
- common/host.nix (import atticd module)
- apps/attic/default.nix, apps/attic/attic-server-token.age (new)
- apps/forgejo/default.nix (gitea -> forgejo binary)
- roles/forge.nix (add attic)
- Justfile (template update)
- AGENTS.md (Service Initialization docs)
- secrets.nix (attic secret)
- All host flake.nix and flake.lock files

### Next Steps
1. Deploy to drhorrible (user will do this)
2. Check `journalctl -u atticd -n 50` for startup error
3. Fix atticd config issue if needed
4. Verify bootstrap creates cache and tokens


