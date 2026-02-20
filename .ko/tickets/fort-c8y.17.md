---
id: fort-c8y.17
status: closed
deps: [fort-c8y.16]
links: []
created: 2026-01-08T04:04:10.013204212Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 5: Migrate SSL certificates to control plane

Replace acme-sync rsync timer with control plane callbacks.

## Current State

- ssl-cert capability handler exists (wildcard only)
- acme-sync timer rsyncs certs to all hosts
- No consumers declared

## Target State

- Hosts declare fort.host.needs.ssl-cert.default
- ssl-cert capability uses async mode with triggers.systemd
- Callbacks push certs to consumers
- Remove acme-sync timer

## Tasks

- [ ] Convert ssl-cert capability to async mode
- [ ] Add triggers.systemd for ACME renewal unit
- [ ] Write ssl-cert consumer handler (stores certs, reloads nginx)
- [ ] Add fort.host.needs.ssl-cert.default to hosts
- [ ] Test cert delivery and nginx reload
- [ ] Remove acme-sync timer from certificate-broker

## Acceptance Criteria

- All hosts receive certs via control plane
- nginx reloads after cert delivery
- Cert rotation works (ACME renewal triggers callback)


