---
id: fort-0aa
status: closed
deps: []
links: []
created: 2026-01-01T17:51:38.338732673Z
type: task
priority: 2
---
# Investigate and fix drhorrible failed unit

drhorrible showing 1 failed unit as of 2026-01-01.

Discovered while debugging headscale outage. Need to identify which unit and fix.

**Update**: Cannot identify failing unit remotely - fort-agent status capability only returns count, not unit names. See fort-ydn for capability enhancement.

To investigate, need to SSH to drhorrible and run:
```
systemctl --failed
```


