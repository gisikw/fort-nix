---
id: fort-ucz
status: closed
deps: []
links: []
created: 2025-12-29T22:40:29.065471823Z
type: feature
priority: 3
---
# Add default nginx vhost with deploy status endpoint

Add a default nginx virtual host on port 80 that serves a simple status page showing:

- Deploy timestamp
- Git SHA / version
- Host name
- Maybe uptime or other quick health indicators

This provides a fast way to verify deploy status without authentication (VPN-gated only).

## Implementation notes

- May require moving some services off port 80 to a different port (nginx can proxy them)
- Should be part of the base host config (common/ or an aspect)
- Could be a static JSON file generated at activation time, or a simple systemd service
- `visibility: local` so it's VPN-only

## Example output

```json
{
  "host": "joker",
  "deployed_at": "2025-12-29T10:30:00Z",
  "git_sha": "abc123f",
  "uptime_seconds": 3600
}
```


