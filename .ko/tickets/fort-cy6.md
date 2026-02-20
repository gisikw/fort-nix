---
id: fort-cy6
status: closed
deps: []
links: []
created: 2025-12-27T23:48:47.590858803Z
type: epic
priority: 1
---
# CI/CD and GitOps Pipeline

Implement a complete CI/CD and GitOps pipeline for fort-nix using Forgejo, Comin, and Attic.

## Motivation

- Enable Claude Code (on ratched devbox) to trigger deployments without root SSH access to production hosts
- Separate secret authorship (editors) from secret decryption (production hosts)
- Eliminate the need for a master deploy key
- Add binary caching for faster deployments across heterogeneous architectures

## Architecture Overview

### Components
- **Forgejo**: Self-hosted git forge on drhorrible (forge role) with Actions CI
- **Comin**: Pull-based GitOps - hosts poll git and self-deploy
- **Attic**: Binary cache - build once, substitute everywhere

### Two-Branch Secrets Model
- `main` branch: secrets keyed for editors only (laptop, ratched, forge)
- `release` branch: CI re-keys secrets for actual host recipients
- Hosts run comin against `release` branch

### Key Design Decisions
- Forge (drhorrible) stays on manual deploy-rs - it's critical infrastructure
- All hosts can read AND write to Attic cache (content-addressing makes poisoning infeasible)
- CI builds all hosts best-effort, targets fill cache gaps via post-deploy hook
- deploy-rs kept as escape hatch for high-risk changes

## Reference
See recommendation.md for full details.


