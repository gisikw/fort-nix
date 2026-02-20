---
id: fort-z0b
status: closed
deps: []
links: []
created: 2025-12-21T12:46:06.509684-06:00
type: bug
priority: 4
---
# Investigate lldap-bootstrap flakiness

lldap-bootstrap.service occasionally fails with 'jq: parse error: Invalid numeric literal at line 1, column 5'. Observed during deploy to drhorrible. May be a race condition or malformed secret file.


