---
id: fort-4ih
status: closed
deps: []
links: []
created: 2025-12-22T00:39:34.734941-06:00
type: bug
priority: 1
---
# Fix claude-code derivation - binary is raw bun, not bundled app

The binary downloaded from Anthropic's GCS bucket is just raw bun runtime, not Claude Code bundled into bun. Need to investigate proper installation - may need to run 'claude install' post-download or use npm package instead.


