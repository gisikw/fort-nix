---
id: fort-89e.3
status: closed
deps: []
links: []
created: 2025-12-30T22:00:55.859422495Z
type: task
priority: 2
parent: fort-89e
---
# fort-agent-call client

Bash script in pkgs/fort-agent-call/:
- Sign request body with host's SSH key (ssh-keygen -Y sign)
- Build canonical string: METHOD\nPATH\nTIMESTAMP\nSHA256(body)
- POST via curl with X-Fort-Origin, X-Fort-Timestamp, X-Fort-Signature headers
- Parse X-Fort-Handle and X-Fort-TTL from response headers
- Expose handle via FORT_HANDLE env var or stdout marker
- Exit codes: 0=success, 1=http error, 2=auth error

Usage: fort-agent-call <host> <capability> [request-json]

## Acceptance Criteria

- Can successfully call agent endpoints on other hosts
- Properly signs requests
- Extracts handle from response headers
- Clear error codes for different failure modes


