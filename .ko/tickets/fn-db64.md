---
id: fn-db64
status: open
deps: []
links: []
created: 2026-02-22T23:10:02Z
type: task
priority: 2
---
# Add GPU recovery script/service for lordhenry

## Notes

**2026-02-22 23:10:27 UTC:** Recovery command: echo 1 > /sys/bus/pci/devices/0000:c5:00.0/remove && sleep 2 && echo 1 > /sys/bus/pci/rescan -- Context: After enabling mmap for ollama, GPU got wedged with GCVM_L2_PROTECTION_FAULT on every compute job. Survived reboots, cold boot, even a full BIOS update (1.05->1.12). Only PCI remove/rescan fixed it. Minimum viable: shell script or systemd oneshot on lordhenry.

**2026-02-22 23:19:04 UTC:** Recommended approach: systemd oneshot that runs PCI reset before ollama starts. Pair with OLLAMA_KEEP_ALIVE=-1 and mmap enabled to load large models. Reset guarantees clean GPU state on every boot. Nix snippet: systemd.services.gpu-reset with ExecStart='echo 1 > /sys/bus/pci/devices/0000:c5:00.0/remove && sleep 2 && echo 1 > /sys/bus/pci/rescan', Type=oneshot, before ollama.service. The fault only triggers on model eviction/unload, not during inference -- so load once, keep alive, reset on boot.
