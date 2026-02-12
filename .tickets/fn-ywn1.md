---
id: fn-ywn1
status: open
deps: [fn-xuvs]
links: []
created: 2026-02-12T18:29:40Z
type: task
priority: 2
assignee: Kevin Gisi
parent: fn-x4ci
tags: [darwin, infrastructure]
---
# Port fort agent to darwin (launchd service)

The fort agent (fort-provider/fort-consumer) needs to run on darwin so the cluster can communicate with the mac host. This means: launchd service definitions instead of systemd, status/manifest/needs capabilities working, journal capability needs darwin-specific log retrieval (log show instead of journalctl). The agent binary itself is Go, so cross-compilation is straightforward.

