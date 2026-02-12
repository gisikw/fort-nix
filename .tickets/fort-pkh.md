---
id: fort-pkh
status: open
deps: []
links: []
created: 2026-01-01T17:51:38.868113768Z
type: task
priority: 2
---
# Audit apps for duplicate nginx proxy headers

NixOS nginx includes recommended proxy headers by default (Host, X-Forwarded-*, etc). Apps that also set these in extraConfig cause duplicate headers.

Headscale was broken by this - duplicate Host header is invalid HTTP/1.1.

Audit other apps and document the pattern in AGENTS.md.


