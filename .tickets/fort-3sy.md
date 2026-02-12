---
id: fort-3sy
status: closed
deps: []
links: []
created: 2026-01-01T17:51:38.693485611Z
type: task
priority: 2
---
# Add nginx->headscale systemd dependency

At boot, nginx starts before headscale is ready to accept connections, causing ~12 seconds of 502/400 errors.

Fix: Add After=headscale.service to nginx on the beacon host.

Context: During 2026-01-01 debugging, saw connection refused errors in nginx logs from boot time.


