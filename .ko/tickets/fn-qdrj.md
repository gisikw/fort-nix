---
id: fn-qdrj
status: closed
deps: []
links: []
created: 2026-02-12T18:29:20Z
type: task
priority: 2
assignee: Kevin Gisi
parent: fn-x4ci
tags: [darwin, infrastructure]
---
# Add nix-darwin flake input

Add nix-darwin as a flake input. Determine whether to add it at the root flake level or per-host. Root level is simpler and consistent with how other inputs (agenix, comin, etc.) are handled.

