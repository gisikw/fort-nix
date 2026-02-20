---
id: fort-89e.2
status: closed
deps: [fort-89e.1]
links: []
created: 2025-12-30T22:00:46.237689762Z
type: task
priority: 2
parent: fort-89e
---
# Go FastCGI wrapper

Implement pkgs/fort-agent-wrapper/main.go (~300 lines):
- Parse X-Fort-Origin, X-Fort-Timestamp, X-Fort-Signature headers
- Verify SSH signature against /etc/fort-agent/hosts.json
- Timestamp validation (reject if >5min drift)
- Check RBAC against /etc/fort-agent/rbac.json
- Exec handler script from /etc/fort-agent/handlers/
- Capture stdout as response body
- Pass through X-Fort-Handle / X-Fort-TTL headers from handler

Signature format: sign(method + path + timestamp + sha256(body)) using ssh-keygen -Y sign format.

## Acceptance Criteria

- Wrapper authenticates requests using SSH signatures
- Invalid signatures return 401
- RBAC violations return 403
- Valid requests dispatch to handler and return response


