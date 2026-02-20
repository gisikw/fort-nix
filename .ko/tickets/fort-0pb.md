---
id: fort-0pb
status: closed
deps: []
links: []
created: 2025-12-28T02:23:10.244451095Z
type: feature
priority: 3
---
# Create skill for SSO integration guidance

## Context
CLAUDE.md documents the SSO modes table and the OIDC credential delivery contract, but implementing other modes (headers, basicauth, gatekeeper) still requires archaeology through examples.

Rather than bloating always-loaded context with howtos for every mode, create a skill that provides mode-specific implementation guidance.

## Proposed skill: `sso-guide`

Progressive disclosure skill that loads when configuring authentication for services.

### Content to extract from AGENTS.md
- "SSO Modes" section (lines 66-75)
- "OIDC Credential Delivery" section (lines 76-110)

### Skill structure
```
.claude/skills/sso-guide/
├── SKILL.md              # Mode selection overview, when to use each
├── oidc.md               # Native OIDC pattern + pocket-id provisioning flow
├── headers.md            # oauth2-proxy X-Auth-* pattern
├── basicauth.md          # Basic auth translation pattern
├── gatekeeper.md         # Login wall pattern
└── troubleshooting.md    # Callback URLs, token scopes, groups claim
```

### Definition of done
- [ ] Skill created in .claude/skills/sso-guide/
- [ ] AGENTS.md SSO section reduced to mode table only (no detailed howtos)
- [ ] Tested: skill loads when discussing SSO configuration

## Labels
dx sso


