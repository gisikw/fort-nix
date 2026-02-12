---
id: fort-qg0
status: closed
deps: []
links: []
created: 2025-12-28T19:59:39.31863417Z
type: task
priority: 1
---
# Complete attic bootstrap script

The attic server runs, but the bootstrap script (ExecStartPost) that creates admin/CI tokens and the cache needs work. Issues encountered:
- atticadm needs a config file with all required fields (chunking, etc.)
- Config must match what atticd uses
- Consider using the same config generation approach as the nixpkgs module

Reference: apps/attic/default.nix ExecStartPost section


