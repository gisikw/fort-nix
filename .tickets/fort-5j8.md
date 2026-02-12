---
id: fort-5j8
status: closed
deps: []
links: []
created: 2025-12-31T04:20:42.29311195Z
type: feature
priority: 3
---
# Skill: add-secret workflow

## Context
Adding secrets involves: creating .age file, updating secrets.nix with recipient keys, understanding principal→recipient mapping. Currently scattered knowledge.

## Proposed skill: `add-secret`

Progressive disclosure skill for agenix secret management.

### Content to extract from AGENTS.md
- "Secrets" section (lines 326-342)
- Dev sandbox decryption testing

### Skill structure
```
.claude/skills/add-secret/
├── SKILL.md              # Workflow: create .age, update secrets.nix
└── recipients.md         # Principal roles → recipient selection
```

### Definition of done
- [ ] Skill created in .claude/skills/add-secret/
- [ ] AGENTS.md secrets section reduced to brief pointer
- [ ] Tested: skill loads when adding encrypted secrets

## Labels
dx


