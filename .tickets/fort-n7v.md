---
id: fort-n7v
status: closed
deps: []
links: []
created: 2026-01-02T06:02:13.206931244Z
type: task
priority: 2
---
# Deduplicate 'Waiting for comin' deploy output

The `just deploy` command outputs repeated 'Waiting for comin to fetch...' and 'Waiting for activation...' lines during GitOps deploys. These burn tokens when running in agent context.

Suggested fix: Only output on state changes, or collapse repeated lines into a single updating line (if terminal supports it), or just silence the repeated attempts entirely and only show the final result.


