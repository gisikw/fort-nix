---
id: fn-akse
status: open
deps: []
links: []
created: 2026-02-14T18:07:06Z
type: task
priority: 2
assignee: Kevin Gisi
---
# darwin: fix pmset activation script warnings on obrien

The mac-mini device profile (`device-profiles/mac-mini/manifest.nix`) uses
`system.activationScripts.postActivation.text` to run `pmset -a` commands for
power management (autorestart, RestartAfterFreeze, womp). On activation, these
produce:

```
Usage: pmset <options>
See pmset(1) for details: 'man pmset'
```

The exit code causes `darwin-rebuild switch` to report exit code 1 even though
the system otherwise activated successfully. Likely needs full path to `pmset`
(`/usr/bin/pmset`) or the flags may differ on this macOS version.

Also: the mesh-enroll launchd daemon races with agenix — both are `RunAtLoad`
with no ordering dependency. If mesh-enroll fires before agenix decrypts, it
fails with "No such file or directory" for `/run/agenix/auth-key`. Consider
adding a wait-for-file loop or explicit ordering.
