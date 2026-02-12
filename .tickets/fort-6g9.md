---
id: fort-6g9
status: closed
deps: []
links: []
created: 2025-12-31T20:23:25.759203034Z
type: feature
priority: 2
---
# Agent debug capabilities

Capabilities to enable agent-driven debug loops without SSH access:

- deploy: trigger comin for on-demand deploys to forge/beacon
- journal: fetch journalctl output for a unit
- restart: restart a systemd unit

This enables a tight debug loop:
1. Push fix
2. fort-agent-call <host> deploy
3. fort-agent-call <host> journal '{"unit": "...", "lines": 50}'
4. Iterate

Removes human-in-loop for forge/beacon deploys while keeping them off automatic GitOps.


