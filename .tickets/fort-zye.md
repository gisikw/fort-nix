---
id: fort-zye
status: open
deps: []
links: []
created: 2026-01-09T15:02:40.971843229Z
type: epic
priority: 3
---
# Radicale: self-hosted calendar for Exocortex

**Desired state:** A self-hosted CalDAV server (Radicale) that Exo can write to, separate from Google Calendar.

**Why:**
- Personal/home calendar separate from work
- Independence from Google
- A calendar that's purely Exo-controlled and doesn't touch work systems

**Stack:** Radicale (CalDAV server) + vdirsyncer + khal

**Requirements:**
- Radicale deployed somewhere in the cluster
- Synced to khal on ratched alongside Google Calendar
- Exo can create events that don't pollute work calendar
- Should integrate cleanly with the work calendar sync (fort-a7j) - merged view in khal

**Context:** This is the second phase of Exocortex calendar integration. Work calendar sync (fort-a7j) should be done first. Related: exocortex-5o6.


