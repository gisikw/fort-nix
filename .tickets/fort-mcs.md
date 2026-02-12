---
id: fort-mcs
status: closed
deps: []
links: []
created: 2026-01-04T06:35:36.389991149Z
type: chore
priority: 2
---
# Tech debt: Apps should accept subdomain parameter

Apps that expose a fort service should accept a subdomain argument that adds/overrides the subdomain in exposedServices.

Context: fortCluster.exposedServices already supports separate name and subdomain fields (e.g., pocket-id uses name="pocket" but subdomain="id" → id.gisi.network).

Proposed pattern:
```nix
# App module accepts subdomain override from host manifest
{ subdomain ? null }:
...
fortCluster.exposedServices = [{
  name = "silverbullet";
  subdomain = subdomain;  # null uses default, or override from manifest
  ...
}];
```

In host manifest:
```nix
apps = [
  { name = "silverbullet"; subdomain = "exocortex"; }
  { name = "silverbullet"; subdomain = "notes"; }
];
```

This enables multiple instances of the same app on different subdomains without duplicating the entire app module.

Audit existing apps and add subdomain parameter where multi-instance makes sense.


