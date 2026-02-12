---
id: fort-c8y.5
status: closed
deps: [fort-c8y.4, fort-c8y.7]
links: []
created: 2026-01-08T04:01:22.174429825Z
type: task
priority: 2
parent: fort-c8y
---
# Phase 2: Add callback endpoint to fort-provider

## Summary

Add endpoint for providers to push responses to consumers, completing the fulfillment loop.

## Design

Route: `POST /fort/needs/<type>/<id>`
Auth: Verify caller matches declared "from" provider in `/etc/fort/needs.json`

## Flow

1. Receive `POST /fort/needs/<type>/<id>` with payload
2. Verify `X-Fort-Origin` matches the `from` field for this need
3. Look up need in `/etc/fort/needs.json` to find handler (if any)
4. Invoke handler with payload on stdin (or interpret payload directly if no handler)
5. Update `/var/lib/fort/fulfillment-state.json` based on result

## State Update Logic

**With handler specified:**
- Handler exits 0 → set `satisfied = true`
- Handler exits non-zero → `satisfied` stays false (nag will retry)

**Without handler (side-effect-only needs):**
- Non-empty response (e.g., "OK") → set `satisfied = true`
- Empty response → set `satisfied = false` (revocation, triggers re-request after nag interval)

## Tasks

- [ ] Add `/fort/needs/<type>/<id>` route handling in fort-agent
- [ ] Verify caller is the declared provider for this need
- [ ] Locate handler script from needs.json (may be null)
- [ ] Invoke handler with payload on stdin, or interpret payload directly
- [ ] Update fulfillment-state.json based on handler exit code or payload content

## Acceptance Criteria

- Provider can POST to consumer callback endpoint
- Handler receives payload on stdin
- Consumer state updated correctly for all cases (handler success/failure, no-handler with/without payload)
- Auth rejects calls from non-providers


