---
id: fort-cy6.23
status: closed
deps: []
links: []
created: 2025-12-28T22:45:39.128879389Z
type: task
priority: 3
parent: fort-cy6
---
# Exhaustive cache sanity check

Full end-to-end validation of binary cache flow after GitOps rollout is complete.

## Checks
- Verify CI pushes for all host architectures
- Confirm substitution logs on multiple hosts
- Check Attic metrics/logs for error rates
- Document observed cache hit rates

## Context
Deferred from fort-cy6.12 - adjacent logs during development gave confidence, but worth a thorough check once everything is stable.


