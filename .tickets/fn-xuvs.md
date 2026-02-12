---
id: fn-xuvs
status: in_progress
deps: [fn-qdrj]
links: []
created: 2026-02-12T18:29:16Z
type: task
priority: 2
assignee: Kevin Gisi
parent: fn-x4ci
tags: [darwin, infrastructure]
---
# Abstract common/host.nix into mkHost with platform dispatch

Split host.nix into shared logic and platform-specific builders. The shared layer handles manifest loading, principal-derived access control, and module composition. Platform-specific layers call nixpkgs.lib.nixosSystem or nix-darwin's darwinSystem respectively. Key decisions: how to handle impermanence (skip on darwin), disko (skip on darwin), agenix (different key paths on macOS).

