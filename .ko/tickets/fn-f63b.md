---
id: fn-f63b
status: open
deps: []
created: 2026-03-29T03:04:42Z
type: task
priority: 2
---
# Harden rekey script: fix silent eval failures.

Harden rekey script: stop swallowing nix eval failures. Line 73 of scripts/rekey.sh uses '|| echo {}' which silently drops hosts whose eval fails, leading to missing keys and failed activations.
