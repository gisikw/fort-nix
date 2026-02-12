---
id: fort-5n3
status: open
deps: []
links: []
created: 2026-01-01T17:51:24.364678997Z
type: task
priority: 2
---
# Self-service tailscale registration behind OIDC

Create a self-registration endpoint protected by Pocket ID OIDC that:
1. Generates a pre-auth key
2. Returns it to the authenticated user
3. Auto-approves the resulting node

This removes the two-step SSH-dependent registration process when a client forgets its config.

Context: During 2026-01-01 outage, macbook tailscale client forgot headscale config entirely, requiring manual re-auth and SSH to approve the key.


