---
id: fort-vpc
status: open
deps: []
links: []
created: 2026-01-04T19:55:57.692785922Z
type: feature
priority: 3
---
# Expand certificate broker for arbitrary domain certs

Currently certificate-broker only generates wildcard certs for the cluster domain. Expand to support generating certs for arbitrary external domains via DNS-01 challenge (configurable in host manifest). Eventually expose via fort-agent-call instead of SSH dropoff.


