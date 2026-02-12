---
id: fort-gel
status: closed
deps: [fort-ax1]
links: []
created: 2025-12-21T11:41:07.941134-06:00
type: feature
priority: 2
---
# Add Termix as hosted app on q

Deploy Termix (github.com/Termix-SSH/Termix) on q host. Fast-moving project, likely needs custom derivation. SSH-based terminal sharing tool.

## Notes

## Resolution: VPN-only + Internal Auth

After investigating Termix OIDC (v1.9.0):
- OIDC still requires Admin UI configuration (no env var support)
- No reverse proxy auth header support (no X-Forwarded-User, etc.)
- Internal auth cannot be disabled

Decision: Deploy behind Tailscale VPN (visibility: vpn, which is default), using Termix's built-in authentication.

### Implementation
- OCI container: ghcr.io/lukegus/termix:latest (via zot proxy)
- Port 8080
- Data persistence: /var/lib/termix:/data
- Service: termix. (VPN-only access)


