---
id: fn-9n3w
status: open
deps: []
links: []
created: 2026-02-18T14:15:21Z
type: task
priority: 2
assignee: Kevin Gisi
---
# obrien: expired deploy token breaks gitops


## Notes

**2026-02-18T14:15:28Z**

The deploy token embedded in obrien's git remote URL (fort-deploy:fb54450ba8...) is expired. The forgejo-deploy-token-sync service distributes tokens to dev-sandbox hosts, but obrien doesn't have the dev-sandbox aspect so it never gets refreshed tokens. The gitops launchd daemon (fort-gitops) has been failing silently with exit code 128. Workaround: rsynced the repo from ratched and ran darwin-rebuild manually. Fix options: (1) add dev-sandbox aspect to obrien, (2) have token sync cover gitops hosts too, (3) manual token rotation.
