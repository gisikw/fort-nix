---
id: fort-4jd
status: open
deps: []
links: []
created: 2025-12-31T04:20:42.451120713Z
type: feature
priority: 3
---
# Skill: debug-deploy troubleshooting

## Context
Deployment debugging requires constructing SSH commands, knowing common failure modes, understanding deploy-rs rollback behavior. AGENTS.md has the basics but could be more comprehensive.

## Proposed skill: `debug-deploy`

Progressive disclosure skill for deployment troubleshooting.

### Content to extract from AGENTS.md
- "Debugging Deployment Failures" section (lines 393-408)
- SSH command templates
- Common issues list

### Skill structure
```
.claude/skills/debug-deploy/
├── SKILL.md              # Systematic debugging flow
├── ssh-commands.md       # Command templates with cluster manifest lookups
└── common-issues.md      # Expanded troubleshooting guide
```

### Definition of done
- [ ] Skill created in .claude/skills/debug-deploy/
- [ ] AGENTS.md debugging section reduced to brief overview
- [ ] Tested: skill loads when deployment fails or debugging discussed

## Labels
dx ops


