---
id: fort-9k0
status: open
deps: []
links: []
created: 2025-12-28T06:48:03.971366754Z
type: task
priority: 3
---
# Investigate nix develop-based runner environment

Explore using `nix develop` to provide runner dependencies from repo flake.

## Problem
Currently the runner PATH is hardcoded in forge config. Adding/updating dependencies requires:
1. Modifying forgejo app module
2. Deploying to forge
3. Restarting runner

This couples runner infrastructure to repo-specific needs (e.g., testing package updates).

## Desired State
Workflows could declare their own dependencies via the repo devShell:

```yaml
- name: Run tests
  run: nix develop -c ./run-tests.sh
```

Or the runner could automatically wrap commands in `nix develop`.

## Investigation Areas
- Can forgejo-runner be configured to wrap commands in `nix develop`?
- Should we create a custom action that enters the devShell?
- Performance implications of nix develop per-step vs per-job
- Caching devShell dependencies

## References
- Current hardcoded PATH: apps/forgejo/default.nix runner config
- Forgejo runner host execution model

## Notes
Low priority - current setup works, this is about flexibility for future needs.


