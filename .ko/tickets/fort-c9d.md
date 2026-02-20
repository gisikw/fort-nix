---
id: fort-c9d
status: closed
deps: []
links: [fort-mcs]
created: 2026-01-04T06:18:58.208878801Z
type: feature
priority: 2
---
# Set up SilverBullet for exocortex PKM

Deploy SilverBullet instance at exocortex.gisi.network fronting ~/Projects/exocortex on ratched dev-sandbox.

Requirements:
- SilverBullet with gatekeeper SSO mode
- Serves markdown from ~/Projects/exocortex (git-tracked)
- File permissions: both SilverBullet and dev user need r/w access
- Same markdown files are:
  - PKM content for SilverBullet
  - Git-tracked context for Claude Code to read/manipulate

Challenges:
- Shared file permissions between silverbullet service user and dev user
- May need group-based permissions or bind mount with appropriate ownership
- Ensuring git operations don't break silverbullet and vice versa

This is the 'markdown as shared context' workflow experiment.


