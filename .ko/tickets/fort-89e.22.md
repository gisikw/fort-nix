---
id: fort-89e.22
status: closed
deps: []
links: []
created: 2025-12-31T02:30:27.203801144Z
type: bug
priority: 2
parent: fort-89e
---
# fort-agent-call: Remove hardcoded values, improve handle output

Issues from code review:

1. **Hardcoded domain**: Line 25 defaults to gisi.network - should either:
   - Inject at derivation time from cluster settings (preferred)
   - Read from /var/lib/fort/cluster.json at runtime
   - Error if FORT_DOMAIN not set (no silent defaults)

2. **Hardcoded example in usage**: 'drhorrible' shouldn't be in the script

3. **stderr for handle/TTL is awkward**: Outputting FORT_HANDLE=... to stderr requires callers to do capture gymnastics. Consider:
   - JSON envelope on stdout: { "body": ..., "handle": ..., "ttl": ... }
   - Separate file output (--handle-file flag)
   - Environment file output that can be sourced

Derivation-time injection is cleanest - the script becomes cluster-specific at build time.

## Acceptance Criteria

- No hardcoded domain or hostname examples
- Handle/TTL available without stderr parsing
- Works correctly with fulfillment service


