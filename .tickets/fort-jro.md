---
id: fort-jro
status: closed
deps: []
links: [fort-19c]
created: 2026-01-04T06:16:21.541457608Z
type: feature
priority: 2
---
# Add Hugo app for static blog hosting

Add Hugo as an app to host a static blog, replacing the S3-hosted blog.

Requirements:
- Hugo with a theme (TBD which theme)
- Build static site from content in repo (see fort-xxx for monorepo content)
- Expose via nginx
- Automatic rebuild on content changes (git push triggers rebuild)

This deprecates the existing S3 blog setup.


