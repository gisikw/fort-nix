---
id: fort-btm
status: closed
deps: []
links: []
created: 2026-01-01T19:59:38.010668187Z
type: task
priority: 2
---
# Auto-populate Termix with configured hosts

Automatically add cluster hosts to Termix so they appear in the SSH connection list without manual configuration.

Likely approach:
- Query cluster manifest for hosts
- Write directly to Termix SQLite database (or use its config format)
- Run on activation or via timer

Should be fun database hackery.


