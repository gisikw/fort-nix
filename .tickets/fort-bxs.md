---
id: fort-bxs
status: open
deps: []
links: []
created: 2026-01-06T04:23:44.540426368Z
type: task
priority: 2
---
# Handle-based credential renewal mechanism

Design pattern for provider-initiated credential renewal:

1. Provider generates credential with handle
2. Client stores handle in holdings
3. Provider detects renewal needed (e.g., ACME cert refreshed)
4. Provider marks handles as stale/invalidated
5. Client's fulfill-retry timer detects stale handle, re-fetches
6. Same transform logic applies new credentials

This enables SSL cert distribution via control plane without a dedicated push mechanism. The provider just invalidates handles, and clients naturally re-fetch.

Related: fort-89e.8 (SSL cert migration), fort-89e.15 (GC foundation)


