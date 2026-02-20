---
id: fort-cy6.24
status: closed
deps: []
links: []
created: 2025-12-29T04:16:37.21179604Z
type: task
priority: 3
parent: fort-cy6
---
# Optimize release workflow: only re-key changed secrets

Currently the release workflow re-keys ALL secrets on every commit. Since age uses random nonces, this produces different ciphertext every time, causing all hosts to see 'changes' and re-evaluate even when their config hasn't changed.

## Optimization

1. Build map of secret path → recipients (already done)
2. Store this map in the release branch (e.g., `.release-recipients.json`)
3. On next run, compare current map to stored map
4. Only re-key secrets whose recipients have changed
5. Update stored map

## Benefits

- Hosts only see derivation changes when their secrets actually changed
- Reduces unnecessary evaluation/build cycles
- More efficient use of cache (unchanged derivations stay cached)

## Notes

- Low priority - current overhead is minimal (eval is fast, builds are cached)
- But easy win for cleaner semantics


