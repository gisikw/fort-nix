---
id: fn-5skl
status: closed
deps: [fn-xuvs]
links: []
created: 2026-02-12T18:29:35Z
type: task
priority: 2
assignee: Kevin Gisi
parent: fn-x4ci
tags: [darwin, infrastructure]
---
# Darwin gitops-lite: launchd-based git pull and darwin-rebuild

Implement a simple GitOps mechanism for darwin hosts. A launchd daemon that periodically polls the release branch and runs darwin-rebuild switch. Doesn't need to be comin — just needs to be reliable. Consider: poll interval, error handling, notification on failure (via fort notify capability), logging.

