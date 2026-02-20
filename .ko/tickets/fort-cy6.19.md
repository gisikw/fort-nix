---
id: fort-cy6.19
status: closed
deps: [fort-cy6.17]
links: []
created: 2025-12-28T00:00:13.749704412Z
type: task
priority: 3
parent: fort-cy6
---
# Document deployment workflows

Document the new deployment workflows and when to use each.

## Context
With GitOps enabled, there are now multiple ways to deploy. Document when to use each.

## Documentation to Create/Update

### Update README.md or create DEPLOYING.md

```markdown
# Deployment Workflows

## GitOps (Default)
Most hosts auto-deploy via comin when changes are pushed to main.

1. Make changes
2. Push to main
3. CI validates and updates release branch
4. Hosts pull and deploy automatically

Affected hosts: all except drhorrible (forge)

## Manual Deploy (Forge Only)
Forge (drhorrible) requires manual deployment:

\`\`\`bash
just deploy drhorrible
\`\`\`

## Manual Deploy (Emergency/Override)
For any host, you can still use deploy-rs:

\`\`\`bash
just deploy <hostname>
\`\`\`

Use this when:
- GitOps is broken
- You need immediate deployment (don't want to wait for CI)
- Testing changes before committing

## High-Risk Changes
For changes that might break SSH/network:

1. Use comin's testing branch feature
2. Or deploy manually with deploy-rs (has rollback)
3. Have console access ready

## Monitoring Deployments
- Forgejo Actions: https://git.fort.gisi.network/infra/fort-nix/actions
- Comin logs: \`journalctl -u comin -f\` on each host
- Grafana: deployment metrics (if configured)
```

### Update Justfile comments
Add comments explaining when to use `just deploy` vs GitOps.

### Update recommendation.md
Mark as implemented, add lessons learned.

## Acceptance Criteria
- [ ] Deployment documentation exists
- [ ] Clear guidance on when to use each method
- [ ] Emergency procedures documented
- [ ] Team knows about the new workflow

## Dependencies
- fort-cy6.17: GitOps must be rolled out first

## Notes
- Keep it concise - developers won't read walls of text
- Include troubleshooting tips
- Link to relevant logs/dashboards


