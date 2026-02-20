---
id: fort-5f9
status: open
deps: []
links: []
created: 2025-12-31T21:52:58.213121699Z
type: task
priority: 4
---
# Optimize just test for faster dev loops

Currently `just test` validates all hosts/devices which takes a while. Since we have CI/CD, consider a lighter validation for dev loops - maybe just targeting known impacted hosts based on changed files, or having a `just test-host <name>` variant.


