---
id: fort-12e
status: closed
deps: []
links: []
created: 2025-12-29T23:25:55.532266246Z
type: bug
priority: 2
---
# Termix loses state on reboot (q)

After q crashed and rebooted, termix lost its state.

## Investigation needed

1. Check where termix stores its state
2. Verify if it's using `/var/lib/termix` or similar (which would be persisted)
3. If it's using a non-persisted location (e.g., `/tmp`, home dir on tmpfs), fix it

## Context

q uses impermanence (tmpfs root with `/persist/system` for state). Services need to store persistent data in `/var/lib` or explicitly configure persistence.

## Fix options

- Configure termix to use `/var/lib/termix` for state
- Or add its state directory to impermanence persistence rules


