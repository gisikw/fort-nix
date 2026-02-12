---
id: fn-70tq
status: open
deps: []
links: []
created: 2026-02-12T21:21:48Z
type: task
priority: 2
assignee: Kevin Gisi
parent: fn-x4ci
tags: [darwin, infrastructure]
---
# Make defaultAspects platform-aware in host.nix

`host-status` is in `defaultAspects` (every host gets it) but it's deeply NixOS-specific — systemd timers, nginx vhosts, socket activation, /proc/uptime. First darwin host will blow up on it.

Options:
- Make `defaultAspects` in host.nix vary by platform (cleanest)
- Add platform branching inside host-status itself (more self-contained but adds complexity to a large module)

Leaning toward platform-aware defaultAspects — darwin hosts probably want a different set of default aspects anyway (no nginx status page, no upload endpoint, etc).
