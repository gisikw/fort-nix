---
id: fort-89e.23
status: closed
deps: []
links: []
created: 2025-12-31T02:30:50.382546326Z
type: bug
priority: 2
parent: fort-89e
---
# fort-agent.nix: Remove hardcoded capability-to-need mapping

Code review issue: capabilityToNeedType mapping on lines 49-55 hardcodes the relationship between capabilities and need types. This is backwards - specifics shouldn't be baked into the abstraction.

Current (bad):
```nix
capabilityToNeedType = {
  "oidc-register" = "oidc";
  "ssl-cert" = "ssl";
  ...
};
```

Fix: Capabilities should declare what they satisfy:
```nix
fort.capabilities.ssl-cert = {
  handler = ./handlers/ssl-cert;
  satisfies = "ssl";  # Links to fort.needs.ssl.*
  needsGC = false;
};
```

This keeps the abstraction clean - new capabilities don't require editing a central lookup table.

Also affects needs.json generation (line 127) which assumes capability = "${needType}-register" - wrong for ssl-cert, etc.

## Acceptance Criteria

- No hardcoded capability/need mappings
- Capabilities declare their own 'satisfies' type
- needs.json correctly references actual capability names


