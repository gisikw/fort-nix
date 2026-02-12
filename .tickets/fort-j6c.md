---
id: fort-j6c
status: open
deps: []
links: []
created: 2025-12-31T04:25:11.970543926Z
type: feature
priority: 3
---
# Skill: add-pkg custom derivation

## Context
Custom derivations in pkgs/ are for external projects not in nixpkgs or too fast-moving. The pattern involves fetchurl, autoPatchelfHook, and proper installation. AGENTS.md has a template but could be more comprehensive.

## Proposed skill: `add-pkg`

Progressive disclosure skill for creating custom derivations.

### Content to extract from AGENTS.md
- "Custom Derivations" section (lines 112-147)
- pkgs/ vs apps/ distinction

### Skill structure
```
.claude/skills/add-pkg/
├── SKILL.md              # When to use pkgs/, structure overview
├── binary-template.nix   # For pre-built binaries
├── source-template.nix   # For building from source
└── examples.md           # Links to zot, other pkgs/
```

### Definition of done
- [ ] Skill created in .claude/skills/add-pkg/
- [ ] AGENTS.md custom derivations section reduced to brief pointer
- [ ] Tested: skill loads when packaging external software

## Labels
dx


