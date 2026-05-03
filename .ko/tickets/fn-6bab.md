---
id: fn-6bab
status: open
deps: []
created: 2026-04-04T16:26:41Z
type: task
priority: 2
---
# Fix joypad_autoconfig_dir path in RetroArch config.

doofenshmirtz: point RetroArch joypad_autoconfig_dir to retroarch-joypad-autoconfig package udev profiles — currently points to empty ~/.config/retroarch/autoconfig/ so controllers have no button mappings. Interim fix is a symlink to the Nix store path. Proper fix: set joypad_autoconfig_dir in the managed retroarch.cfg or symlink in the media-kiosk module. The package is retroarch-joypad-autoconfig and the profiles live at ${pkg}/share/libretro/autoconfig/udev/
