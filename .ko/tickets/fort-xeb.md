---
id: fort-xeb
status: closed
deps: []
links: []
created: 2025-12-21T22:38:47.981881-06:00
type: task
priority: 3
---
# Document service registry OIDC provisioning flow

The dummy-creds-then-real-creds flow via service-registry is non-intuitive. Add docs to AGENTS.md or README explaining: 1) oauth2-proxy starts with placeholder creds, 2) service-registry provisions real OIDC clients, 3) proxy gets restarted with real creds


