---
id: fort-beu
status: open
deps: []
links: []
created: 2026-01-01T19:51:45.940347811Z
type: task
priority: 2
---
# Set up home-config repo in dev-sandbox and Forgejo

Mirror the home-config (home-manager) repo into Forgejo and make it accessible from dev-sandbox, similar to fort-nix.

- Import repo into Forgejo under infra org
- Set up GitHub mirror (if desired)
- Clone into dev-sandbox workspace
- Ensure git credentials work for push

This makes it easier to iterate on home-manager config alongside infrastructure changes.


