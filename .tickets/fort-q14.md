---
id: fort-q14
status: closed
deps: []
links: []
created: 2025-12-31T21:33:47.227104621Z
type: task
priority: 3
---
# Add SSH key for dev-sandbox principal

Add an SSH public key to the dev-sandbox principal for direct SSH access to dev-sandbox hosts.

Currently dev-sandbox only has an age key (for secrets) and an agentKey (for fort-agent-call signing). Adding an SSH key would allow SSH access to hosts with the dev-sandbox aspect, useful for:
- Termix integration
- Direct terminal access without reusing the admin key

Update clusters/bedlam/manifest.nix to add publicKey to dev-sandbox principal.


