---
id: fort-c8y.22
status: closed
deps: []
links: []
created: 2026-01-10T16:50:58.24932653Z
type: task
priority: 3
parent: fort-c8y
---
# Remove deprecated /agent/ nginx location

After fort-c8y.3 (rename paths/services) is deployed to all hosts, the /agent/ nginx location can be removed.

Currently we have dual paths (/fort/ and /agent/) for transition compatibility. Once all hosts are confirmed running the new paths, remove the deprecated /agent/ location.

Prereq: Verify all hosts are running fort-c8y.3 or later.


