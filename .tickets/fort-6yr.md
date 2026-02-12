---
id: fort-6yr
status: open
deps: []
links: []
created: 2025-12-31T04:25:11.81763913Z
type: feature
priority: 3
---
# Skill: add-aspect workflow

## Context
Aspects are reusable cross-cutting concerns (mesh, observable, egress-vpn, etc.). Adding one involves understanding parameterized vs simple aspects, the aspects/ directory structure, and how they integrate with host manifests.

## Proposed skill: `add-aspect`

Progressive disclosure skill for creating new aspects.

### Content to extract from AGENTS.md
- "Parameterized Aspects" section (lines 202-214)
- Aspect directory structure from codebase navigation

### Skill structure
```
.claude/skills/add-aspect/
├── SKILL.md              # When to use aspects vs apps, structure overview
├── template.nix          # Base aspect template
└── examples.md           # Links to mesh, egress-vpn, zigbee2mqtt
```

### Definition of done
- [ ] Skill created in .claude/skills/add-aspect/
- [ ] AGENTS.md parameterized aspects section reduced to brief pointer
- [ ] Tested: skill loads when creating new aspects

## Labels
dx


