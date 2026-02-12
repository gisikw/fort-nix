---
id: fn-tffw
status: open
deps: []
links: []
created: 2026-02-12T18:29:51Z
type: task
priority: 3
assignee: Kevin Gisi
parent: fn-x4ci
tags: [darwin, ios]
---
# Xcode version management script

A script (living in the nix repo) that ensures the correct Xcode version is installed on a darwin host. Uses xcodes CLI to install/switch versions. Can be a launchd oneshot that runs on boot or after gitops rebuild. Accepts desired version from host manifest or config. The bloated bash file we're fine with.

