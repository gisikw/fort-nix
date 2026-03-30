---
id: fn-eeae
status: closed
deps: []
created: 2026-03-29T22:24:07Z
type: task
priority: 2
---
# Fix RetroArch config: gl instead of vulkan

doofenshmirtz: change retroarch video_driver from vulkan to gl in /home/kids/.config/retroarch/retroarch.cfg — immediate fix for reliable game freezes (Vulkan swapchain deadlocks on Wayland frame callbacks under Cage on Intel N150 integrated graphics). The overlay rebuild will handle this declaratively going forward, but the host config needs patching now so the kids can play.
