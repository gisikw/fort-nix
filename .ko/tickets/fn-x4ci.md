---
id: fn-x4ci
status: open
deps: []
links: []
created: 2026-02-12T18:29:10Z
type: epic
priority: 2
assignee: Kevin Gisi
tags: [darwin, infrastructure]
---
# nix-darwin host support

Support macOS (nix-darwin) hosts as cluster members. Initial use case: headless Mac mini as iOS build box and Forgejo runner. Requires abstracting common/ to dispatch between nixosSystem and darwinSystem, porting mesh aspect, adding a gitops-lite mechanism for darwin, and getting the fort agent running on macOS.

