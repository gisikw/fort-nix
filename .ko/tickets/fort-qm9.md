---
id: fort-qm9
status: open
deps: []
links: []
created: 2026-01-10T01:13:32.490727227Z
type: task
priority: 2
---
# Add docker.io user images to zot sync

The zot registry only syncs from docker.io/library (official images) and ghcr.io. User images like dullage/flatnotes need to be pulled directly from Docker Hub.

Add a sync config for docker.io user namespace images so containers can be pulled through the local registry like other apps (e.g., sillytavern uses ghcr.io through local registry).

Reference: apps/zot/default.nix sync config


