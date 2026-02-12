---
id: fort-89e.24
status: closed
deps: []
links: []
created: 2025-12-31T04:22:41.789548078Z
type: task
priority: 2
parent: fort-89e
---
# Dev-sandbox agent identity for direct agent calls

Enable dev-sandbox users to make fort-agent-call directly (not via sudo).

Current state:
- fort-agent-call signs with /etc/ssh/ssh_host_ed25519_key (root-only)
- dev user cannot access this key
- Agent calls from dev-sandbox require root

Proposed solution:
1. Generate a dedicated agent key for dev-sandbox at /var/lib/fort/dev-sandbox/agent-key
2. Make it readable by the dev user (or dev group)
3. Extend hosts.json generation to include this key under identity "dev-sandbox" or similar
4. Set FORT_SSH_KEY and FORT_ORIGIN env vars in dev-sandbox shell profile

This introduces non-host principals to the agent RBAC system. The dev-sandbox would authenticate as its own identity, not as the host.

Considerations:
- RBAC implications: should dev-sandbox have same access as the host, or restricted?
- Key generation: at host activation time, or as part of dev-sandbox aspect?
- Identity naming: "dev-sandbox", "ratched-dev", or principal-based?


