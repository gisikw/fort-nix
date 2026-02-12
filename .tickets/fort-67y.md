---
id: fort-67y
status: closed
deps: []
links: []
created: 2025-12-31T04:56:47.845146453Z
type: task
priority: 2
---
# Add cluster-level flakes as intermediary between root and host flakes

## Context

Host flakes currently `follows` the root flake for inputs. We want cluster-specific inputs (like home-manager configs) without polluting the root flake.

## Proposed Structure

```
root flake (core inputs: nixpkgs, agenix, deploy-rs, etc.)
    ↑ follows
cluster flake (cluster-specific inputs like home-kevin, cluster config)
    ↑ follows
host flake (nixosConfiguration, inherits from cluster)
```

## Changes

1. Add `clusters/bedlam/flake.nix`:
   - `follows` root flake for core inputs
   - Adds cluster-specific inputs (e.g., `home-kevin.url = "github:gisikw/home-config"`)
   - Exports those inputs for hosts to consume

2. Update host flakes to `follows` cluster flake instead of root directly

3. Update `just deploy` / `just test` if needed to evaluate from the right entry point

## Motivation

- Cluster-level inputs stay in cluster config (consistent with domain, principals being cluster-level)
- Enables home-manager configs to be specified per-cluster without hardcoding in root
- Cleaner separation: root = shared infra, cluster = "my stuff"


