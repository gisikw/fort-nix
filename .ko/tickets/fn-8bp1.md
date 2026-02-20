---
id: fn-8bp1
status: open
deps: []
links: []
created: 2026-02-14T23:56:11Z
type: task
priority: 4
assignee: Kevin Gisi
---
# Auto-create GitHub repos from forge config

When a new repo is added to `fortConfig.forge.repos` with a GitHub mirror, the
forgejo-bootstrap creates the Forgejo repo and configures the push mirror
automatically — but the GitHub repo still has to be created manually via the web
UI, and the PAT's fine-grained repo scope has to be updated to include it.

Extend the bootstrap (or add a separate oneshot) to:
1. Use the GitHub API to create the repo if it doesn't exist
2. Ideally also update the PAT's repo scope (may not be possible via API — if
   not, at least surface a clear log message that the token needs updating)

Current pain: pure clickops on the GitHub side every time we add a repo.
