---
id: fort-48d
status: closed
deps: []
links: []
created: 2026-01-06T04:15:19.172643643Z
type: bug
priority: 2
---
# fort-agent should restart when capabilities change

The fort-agent wrapper reads handler config at startup. When capabilities change via deploy, the agent doesn't pick them up until manually restarted.

Should add a PathChanged or similar trigger on /etc/fort-agent/handlers/ or /etc/fort-agent/capabilities.json to auto-restart.

Related: fort-5bj (agent needs restart after deploy)


