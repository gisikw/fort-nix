---
id: fort-bkv
status: closed
deps: []
links: []
created: 2025-12-30T21:14:14.218020738Z
type: bug
priority: 3
---
# Typo in outline tmpfiles: fort-authy instead of fort-auth

In apps/outline/default.nix, the tmpfiles rule has a typo:

```nix
systemd.tmpfiles.rules = [
  "d /var/lib/fort-authy/outline 0700 outline outline -"  # Should be fort-auth
];
```

This might be causing credential directory issues. Found during control plane design audit.


