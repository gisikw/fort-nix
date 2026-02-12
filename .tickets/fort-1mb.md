---
id: fort-1mb
status: open
deps: []
links: []
created: 2026-01-08T05:43:43.31980399Z
type: task
priority: 2
---
# Patch Termix to keep admin password login enabled

When bootstrap disables password login, it locks out the admin user we created, preventing future OIDC reconfiguration. Patch Termix to either: (1) keep password login enabled for the admin user only, or (2) find another way to preserve admin access for OIDC config changes. This caused a lockout when pocket-id credentials rotated.


