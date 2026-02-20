---
id: fort-040
status: open
deps: []
links: []
created: 2025-12-21T23:56:02.129313-06:00
type: bug
priority: 4
---
# oauth2-proxy groups claim not working with Pocket ID

oauth2-proxy configured with --scope=groups and --oidc-groups-claim=groups but still returns 403 for users in the allowed group. Pocket ID supports groups scope/claim per OIDC discovery. Needs investigation.


