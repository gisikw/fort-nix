---
id: fort-c8y.24
status: closed
deps: []
links: []
created: 2026-01-11T04:17:42.069695163Z
type: task
priority: 2
parent: fort-c8y
---
# Socket-activated services don't restart on binary change

fort-provider.service (socket-activated) doesn't restart when the Go binary changes during NixOS activation. The socket stays active with the old process.

Discovered during fort-c8y.3 rollout - all auto-deploy hosts needed manual `systemctl restart fort-provider.service`.

Fix: Add `restartTriggers` to the service definition referencing the package, or investigate why socket-activated services skip the restart logic.


