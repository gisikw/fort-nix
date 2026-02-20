---
id: fort-nz6
status: closed
deps: []
links: []
created: 2026-01-01T03:19:28.795667868Z
type: task
priority: 2
---
# Add dual-mode deploy to justfile (GitOps + deploy-rs)

Reduce friction for autonomous deploys by making just deploy auto-detect the appropriate flow based on master key presence.

Changes:
- Add deploy.pending field to host-status (shows SHA comin has fetched but not activated)
- Update justfile deploy to use GitOps flow when master key absent, deploy-rs when present
- GitOps flow polls status until pending matches, triggers deploy, waits for activation


