---
id: fort-5of
status: open
deps: []
links: []
created: 2026-01-02T06:33:43.682962595Z
type: task
priority: 2
---
# Move HA device helpers to apps/homeassistant/

The device helper functions in devices.nix (mkAqaraContactSensor, mkHueLight, mkSenckitAlarm, etc.) aren't cluster-specific - they define entity naming patterns for device types.

These should live in apps/homeassistant/ as shared helpers, while the actual device instantiations (mkSenckitAlarm "bedroom_4__alarm") remain in the host-specific devices.nix.


