---
id: fort-89e.6
status: closed
deps: [fort-89e.4, fort-89e.5]
links: []
created: 2025-12-30T22:02:34.465157032Z
type: task
priority: 2
parent: fort-89e
---
# ssl-cert capability

Handler on forge that returns SSL cert files:

Request: { domain: "example.com" } (or could be implicit from cluster)
Response: { cert: "base64...", key: "base64...", chain: "base64..." }

Reads from /var/lib/acme/<domain>/ (existing ACME cert location).
No handle needed - certs are idempotent, no GC required.

Declare via fort.capabilities.ssl-cert in certificate-broker aspect.

## Acceptance Criteria

- Handler returns valid cert data as JSON
- Works with existing ACME-managed certs
- Callable by any cluster host


