---
id: fn-60ne
status: open
deps: [fn-xuvs]
links: []
created: 2026-02-12T18:29:30Z
type: task
priority: 2
assignee: Kevin Gisi
parent: fn-x4ci
tags: [darwin, infrastructure]
---
# Port mesh aspect to support nix-darwin

The mesh aspect (tailscale) is nearly portable — nix-darwin has services.tailscale. Main changes: conditional module loading based on platform, auth key path may differ. This is the critical connectivity aspect that makes the darwin host a cluster member.

