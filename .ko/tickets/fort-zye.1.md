---
id: fort-zye.1
status: closed
deps: []
links: []
created: 2026-01-09T15:03:15.971899007Z
type: task
priority: 3
parent: fort-zye
---
# Break down Radicale epic into tickets

**Instructions for local agent:**

1. Read the parent epic (fort-zye) for desired state
2. Explore the fort-nix codebase to understand:
   - Where Radicale would fit (which host, which cluster)
   - How to expose it (internal only? via Tailscale?)
   - Storage/backup considerations
   - How it interacts with the work calendar sync (fort-a7j)
3. Clarify any ambiguities with Kevin
4. Create tickets under this epic for the actual implementation work

**Dependency:** fort-a7j (work calendar sync) should be done first - this epic builds on that foundation.

This ticket was created by Exo (exocortex) as a cross-repo handoff.


