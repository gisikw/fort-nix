---
id: fort-w38
status: open
deps: []
links: []
created: 2026-01-09T15:04:20.833547733Z
type: feature
priority: 3
---
# Track and alert on stale container image versions

Container apps (homepage, sillytavern, super-productivity) are now pinned to explicit versions, but there's no mechanism to detect when newer versions are available.

Ideas:
- Script that compares pinned versions to latest releases (similar to fort-dfk for pkgs/)
- Could integrate with observability stack for alerts
- Or periodic report during deploys
- Some apps self-nag but not all

Related: fort-dfk covers pkgs/ derivations, this covers OCI containers.

Current pinned versions (as of 2026-01-09):
- homepage: v1.8.0
- sillytavern: 1.15.0  
- super-productivity: v16.8.1


