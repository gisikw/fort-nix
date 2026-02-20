---
id: fort-rp3
status: closed
deps: [fort-0by]
links: []
created: 2026-01-02T15:25:55.571493109Z
type: task
priority: 1
---
# Auto-provision Termix OIDC client

Set up OIDC authentication for Termix without clickops. Options:

1. Bootstrap service that creates admin user on first run, stores credentials in /var/lib, then uses admin API to configure OIDC
2. Direct DB manipulation (less ideal)

Termix's pattern is 'first user is admin', so bootstrap would need to:
- Create admin user if not exists
- Store admin credentials to /var/lib/termix/
- Use those credentials for subsequent OIDC configuration

May need to clear existing app state if admin already exists from clickops setup.


