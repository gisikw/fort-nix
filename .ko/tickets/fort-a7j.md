---
id: fort-a7j
status: closed
deps: []
links: []
created: 2026-01-09T15:01:50.778594299Z
type: epic
priority: 2
---
# Work calendar sync for Exocortex

**Desired state:** Claude (Exo) can view and write to Kevin's Google Workspace calendar via CLI.

**Stack:** vdirsyncer (bidirectional sync) + khal (CLI interface)

**Requirements:**
- Bidirectional sync with Google Calendar (read AND write)
- khal available on ratched (dev-sandbox) for CLI access
- Systemd timer for periodic sync (start with 15 min interval)
- Exo should be able to check sync freshness (file mtimes or similar)

**Use cases:**
- 'You have a 1:1 in 30 minutes'
- 'Your afternoon looks clear for deep work'
- Timeblocking: Exo creates calendar events for focus time
- Awareness of surprise meetings from Product

**Context:** This is part of Exocortex calendar integration (exocortex-5o6). Radicale for a separate self-hosted calendar is a follow-on epic.


