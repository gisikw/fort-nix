---
id: fort-qmg
status: closed
deps: []
links: []
created: 2026-01-01T19:49:01.446572019Z
type: task
priority: 2
---
# Persist tmux session across disconnects in dev-sandbox

When reconnecting to the dev sandbox, automatically reattach to the last active tmux session instead of starting fresh.

Track last connected session so disconnects/reconnects come back to the same place. Consider:
- Session naming convention
- Auto-attach on SSH login
- Cleanup of stale sessions


