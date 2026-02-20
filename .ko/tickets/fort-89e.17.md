---
id: fort-89e.17
status: closed
deps: [fort-89e.16, fort-89e.7]
links: []
created: 2025-12-30T22:05:29.325064741Z
type: task
priority: 2
parent: fort-89e
---
# Wire exposedServices.visibility=public to proxy needs

Auto-generate fort.needs.proxy from exposedServices:

When a service declares visibility = 'public':
- Generate fort.needs.proxy.<service> automatically
- Provider: beacon host
- Request: { service, fqdn, upstream }

This replaces the service-registry scan that finds public services and pushes nginx config.

Implementation in common/fort.nix or related module.

## Acceptance Criteria

- Public services automatically get proxy needs generated
- No manual fort.needs.proxy declaration required
- Proxy configuration happens via fulfillment


