---
id: fort-a7j.2
status: closed
deps: []
links: []
created: 2026-01-10T03:31:28.300811357Z
type: task
priority: 2
parent: fort-a7j
---
# Create Google Cloud OAuth credentials for calendar sync

**Type:** Manual prerequisite (documentation/instructions, not code)

**Steps:**
1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project (or use existing)
3. Enable the CalDAV API (not the Calendar API - different thing)
4. Create OAuth 2.0 Client ID credentials:
   - Application type: Web application
   - Authorized redirect URI: `https://vdirsyncer-auth.<domain>/callback`
5. Save client_id and client_secret

**Output:**
- `client_id` and `client_secret` to be encrypted as agenix secret
- Document the project/credential names somewhere for future reference

**Notes:**
- This is a one-time manual step that Kevin needs to do
- The redirect URI will point to the auth helper service (next ticket)


