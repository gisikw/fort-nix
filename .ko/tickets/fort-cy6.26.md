---
id: fort-cy6.26
status: closed
deps: []
links: []
created: 2025-12-29T22:00:13.915937453Z
type: task
priority: 3
parent: fort-cy6
---
# Reorder CI: validate before rekey

Currently the CI workflow has 'rekey for release branch' and 'validate the build' as separate jobs. The rekey should only happen after validation passes - no point rekeying secrets for a build that won't work.


