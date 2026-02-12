---
id: fort-19c
status: closed
deps: []
links: []
created: 2026-01-04T06:19:23.120183721Z
type: feature
priority: 2
---
# Add blog content to fort-nix monorepo

Move blog content into fort-nix repository. Full monorepo mode.

Rationale: If we can have in this repo:
- Home Assistant automations
- Runtime orchestration  
- OIDC reconciliation
- Infrastructure as code

...then blog posts can be declarative too.

Structure TBD, probably:
```
content/
  blog/
    posts/
      2024-01-01-my-post.md
    pages/
      about.md
```

Pairs with Hugo app (fort-xxx) for build/serve.


