---
id: fort-c8y.25
status: open
deps: []
links: []
created: 2026-01-11T06:41:53.848000895Z
type: task
priority: 4
parent: fort-c8y
---
# Move RW git token out of needs flow

The dev-sandbox RW git token is currently served via the needs schema, but this is awkward:

- Needs are host-scoped, but RW access is a user/principal concern
- We worked around this by allowing ratched host to request RW (fort-c8y.8)
- Better model: dev user makes direct `fort` calls for privileged operations

## Current State

- `fort.host.needs.git-token.dev` on ratched requests RW token at boot
- Token stored at `/var/lib/fort-git/dev-token`
- Works, but conceptually wrong - host shouldn't "need" user-level credentials

## Target State

Options to consider:
1. On-demand: dev user runs `fort drhorrible git-token '{"access":"rw"}'` when needed
2. Session-based: generate token on SSH login, invalidate on logout
3. Keep as-is if the complexity isn't worth it

## Acceptance Criteria

- Dev can push to forge without boot-time token distribution
- Token lifecycle tied to user session, not host boot


