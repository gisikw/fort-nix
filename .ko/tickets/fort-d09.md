---
id: fort-d09
status: closed
deps: []
links: []
created: 2025-12-31T04:20:42.131126189Z
type: feature
priority: 3
---
# Skill: add-app guided workflow

## Context
Adding a new app to fort-nix involves multiple steps: creating the module, choosing SSO mode, setting up tmpfiles, adding to host manifest. AGENTS.md documents the pattern but it's ~40 lines of always-loaded context.

## Proposed skill: `add-app`

Progressive disclosure skill that loads when adding new services.

### Content to extract from AGENTS.md
- "Adding an App" section (lines 42-60)
- fortCluster.exposedServices boilerplate
- Host manifest addition pattern

### Skill structure
```
.claude/skills/add-app/
├── SKILL.md              # Overview, when to use, high-level steps
├── template.nix          # Base app template with placeholders
└── examples.md           # Links to outline, pocket-id, forgejo
```

### Definition of done
- [ ] Skill created in .claude/skills/add-app/
- [ ] AGENTS.md "Adding an App" section reduced to 2-3 sentence overview pointing to skill
- [ ] Tested: skill loads when discussing new app creation

## Labels
dx


