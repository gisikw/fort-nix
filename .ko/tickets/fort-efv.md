---
id: fort-efv
status: closed
deps: [fort-040]
links: []
created: 2025-12-22T00:30:13.582813-06:00
type: task
priority: 2
---
# Remove claude-code-ui internal auth once groups restriction works

Once fort-040 (oauth2-proxy groups claim) is fixed, disable or bypass the internal username/password auth in claude-code-ui. VPN + gatekeeper + groups should be sufficient.


