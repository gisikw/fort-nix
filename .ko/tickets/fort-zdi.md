---
id: fort-zdi
status: closed
deps: []
links: []
created: 2026-01-02T17:17:16.366811019Z
type: task
priority: 2
---
# Migrate container apps off :latest tags

Audit and pin explicit versions for container apps currently using :latest:

- apps/homepage (ghcr.io/gethomepage/homepage:latest)
- apps/sillytavern (ghcr.io/sillytavern/sillytavern:latest)

Pinning versions prevents surprise breakage when cache invalidates and ensures reproducible deploys.


