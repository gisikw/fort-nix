---
id: fn-4uw6
status: open
deps: [fn-ywn1, fn-60ne]
links: []
created: 2026-02-12T18:29:45Z
type: task
priority: 2
assignee: Kevin Gisi
parent: fn-x4ci
tags: [darwin, ios]
---
# Add Forgejo runner app for darwin

Create apps/forgejo-runner/ with darwin support (or extend existing forgejo runner config). The runner registers with drhorrible and picks up CI jobs. On darwin this is a launchd daemon. Needs: Xcode CLI tools available in PATH, signing credentials accessible, runner token from forge.

