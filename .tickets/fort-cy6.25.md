---
id: fort-cy6.25
status: closed
deps: []
links: []
created: 2025-12-29T21:57:53.04155595Z
type: task
priority: 3
parent: fort-cy6
---
# Consolidate host-manifest.json and services.json

The new host-manifest.json includes apps, aspects, and roles. We should extend it to also include exposedServices and update service-registry to read from this single manifest instead of having two redundant files (services.json and host-manifest.json).


