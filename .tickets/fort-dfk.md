---
id: fort-dfk
status: open
deps: []
links: []
created: 2026-01-01T19:49:00.750342402Z
type: task
priority: 2
---
# Track and manage pinned package versions in pkgs/

Custom derivations in pkgs/ (termix, zot, etc.) can go stale when upstream releases new versions.

Ideas:
- Inventory current pins and their upstream sources
- Consider renovate/dependabot-style automation
- At minimum, document how to check for updates
- Maybe a simple script that compares pinned versions to latest releases


