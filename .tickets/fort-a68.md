---
id: fort-a68
status: closed
deps: []
links: []
created: 2025-12-28T02:29:14.029129834Z
type: task
priority: 2
---
# Add just task to trigger service-registry remotely

## Problem
Currently requires manual SSH to drhorrible to run:
```bash
systemctl start fort-service-registry.service
systemctl status fort-service-registry.service
```

## Solution
Add a Just task that:
1. Infers the forge host from the cluster (whoever has the `forge` role)
2. SSHs and triggers the service
3. Waits and shows status output

Something like:
```
just sync-services
```

## Notes
- Should use the SSH key from cluster manifest
- Don't hardcode drhorrible - derive from role assignment


