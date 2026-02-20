---
id: fn-xjmr
status: closed
deps: []
links: []
created: 2026-02-12T18:29:25Z
type: task
priority: 2
assignee: Kevin Gisi
parent: fn-x4ci
tags: [darwin, infrastructure]
---
# Create darwin device profile

Create device-profiles/mac-mini/ (or similar) for macOS hosts. Unlike Linux device profiles, this won't have disko disk layout or boot config. It should handle: system defaults (disable auto-update, sleep, screen saver), power management (restart on power failure, restart on freeze), and any macOS-specific hardening for a headless server.

