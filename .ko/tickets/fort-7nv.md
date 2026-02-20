---
id: fort-7nv
status: closed
deps: []
links: []
created: 2025-12-31T18:58:56.836896359Z
type: task
priority: 2
---
# Triggerable gitops deploys for forge/beacon

Currently forge (drhorrible) and beacon (raishan) require manual deploys via `just deploy`, which is getting onerous. These hosts are excluded from auto-deploy because we don't want them deploying willy-nilly on every push.

Consider options for triggerable gitops-based deploys:
- Manual trigger in CI (workflow_dispatch or similar)
- Approval-gated deploys (require human click before deploy runs)
- Separate deploy branch that only updates on explicit action
- Webhook-triggered deploys from a trusted source
- Combination: auto-deploy on release, but forge/beacon require approval step

Constraints:
- Must not auto-deploy on every push to main/release
- Should still go through CI validation
- Ideally integrates with existing comin/gitops infrastructure
- Need to maintain ability to quickly deploy in emergencies


