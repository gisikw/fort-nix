---
id: fort-2zd
status: open
deps: []
links: []
created: 2026-01-10T16:49:01.266812569Z
type: task
priority: 4
---
# Decompose common/fort.nix into modular concerns

common/fort.nix is currently handling multiple concerns:
- Service exposure (fort.cluster.services)
- nginx virtual host generation
- oauth2-proxy setup
- SSL certificate handling

Now that common/fort/ exists (with control-plane.nix), consider decomposing fort.nix into:
- common/fort/services.nix - service exposure
- common/fort/nginx.nix - virtual host generation
- common/fort/auth.nix - oauth2-proxy/SSO

common/fort.nix would become a simple aggregator that imports from common/fort/*.

Low priority - current structure works, this is about maintainability.


