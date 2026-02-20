---
id: fort-549
status: open
deps: []
links: []
created: 2025-12-30T07:38:10.952090605Z
type: feature
priority: 3
---
# Derive VPN CIDR from mesh config instead of hardcoding

The nginx geo block in common/fort.nix hardcodes 100.64.0.0/10 (Tailscale's CGNAT range). This should be derived from mesh/tailscale config to avoid magic numbers that happen to align with our tailnet setup.


