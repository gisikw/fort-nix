---
id: fort-89e.11
status: closed
deps: [fort-89e.4, fort-89e.5]
links: []
created: 2025-12-30T22:03:54.859465037Z
type: task
priority: 2
parent: fort-89e
---
# attic-token capability

Handler on forge that creates/returns Attic cache tokens:

Request: { host: "ursula" }
Response: { token: "..." }
Handle: yes (for GC)

Uses attic CLI to create token with appropriate permissions.
Replaces current token distribution in attic bootstrap.

## Acceptance Criteria

- Handler creates attic token via CLI
- Returns handle for GC tracking
- Token has correct cache permissions


