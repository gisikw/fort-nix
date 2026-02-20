---
id: fort-4ge
status: open
deps: []
links: []
created: 2025-12-21T11:41:08.858223-06:00
type: feature
priority: 3
---
# Module refactor: express inter-service dependencies

Currently host manifests must 'just know' service dependencies. Refactor to load unparameterized module definitions into a dict first, allowing modules to express dependencies on other services (e.g., zigbee2mqtt depends on mosquitto). Manifests then select from available modules.


