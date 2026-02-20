---
id: fort-49n
status: open
deps: [fort-4fm]
links: []
created: 2025-12-21T11:41:08.545668-06:00
type: feature
priority: 2
---
# Wire more services behind Pocket ID/LDAP auth

Extend SSO coverage. Candidates: SillyTavern, qbittorrent (likely feasible). Jellyfin, Home Assistant (harder - native auth integration). Current SSO modes: none, oidc, headers, basicauth, gatekeeper. Need to verify each service's auth capabilities.


