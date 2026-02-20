---
id: fort-89e.7
status: closed
deps: [fort-89e.3, fort-89e.5]
links: []
created: 2025-12-30T22:03:02.10662668Z
type: task
priority: 2
parent: fort-89e
---
# fort-fulfill.service

Systemd oneshot that runs on activation:

1. Read /var/lib/fort/needs.json
2. For each need where store path doesn't exist (or no handle file):
   - Call provider via fort-agent-call
   - On 2xx: store response at declared path, restart declared services
   - On non-2xx: log warning, continue to next need
3. Exit 0 even if some needs failed (best-effort)

Add fort-fulfill-retry.timer:
- Runs every 5 minutes
- Re-attempts any needs that haven't succeeded
- Stops retrying once all needs fulfilled

Key principle: fulfillment never blocks deploy.

## Acceptance Criteria

- Service runs on activation
- Successfully fulfilled needs have response stored
- Failed needs logged but don't block
- Retry timer re-attempts failures
- Dependent services restarted after fulfillment


