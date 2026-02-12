---
id: fort-89e.16
status: closed
deps: [fort-89e.4, fort-89e.5]
links: []
created: 2025-12-30T22:04:56.988134132Z
type: task
priority: 2
parent: fort-89e
---
# proxy-configure capability

Handler on beacon that configures nginx reverse proxy:

Request: { service: "outline", fqdn: "outline.example.com", upstream: "10.0.0.5:4654" }
Response: { configured: true }
No handle - beacon maintains its own nginx state.

Generates server block, writes to /var/lib/fort/nginx/services/<service>.conf, reloads nginx.
Replaces public_vhosts logic in service-registry.

2xx = 'I have configured the proxy for this service'

## Acceptance Criteria

- Handler generates valid nginx config
- nginx reloads successfully
- Service is accessible through beacon


