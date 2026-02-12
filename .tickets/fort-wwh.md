---
id: fort-wwh
status: open
deps: []
links: []
created: 2026-01-02T06:11:10.233395583Z
type: task
priority: 2
---
# Egress alert: skip notification to dismisser

When someone dismisses the egress door alert, the 'Door alert cleared' notification currently goes to all recipients. It would be better to skip sending to whoever actually pressed the dismiss button.

Requires tracking who dismissed (possibly via separate input_button per adult, or via HA user context if available).


