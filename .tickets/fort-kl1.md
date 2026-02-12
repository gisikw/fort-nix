---
id: fort-kl1
status: closed
deps: []
links: []
created: 2025-12-21T22:20:30.351213-06:00
type: bug
priority: 2
---
# Age files must be committed before deploy to avoid revert

When age files are modified but not committed, the deploy process may revert them due to rekeying logic. This is a footgun for operators.


