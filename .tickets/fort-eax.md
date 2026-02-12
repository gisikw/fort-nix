---
id: fort-eax
status: closed
deps: []
links: []
created: 2025-12-28T15:38:02.099786945Z
type: task
priority: 4
---
# Increase Nix download-buffer-size for hosts

During the attic deploy, download buffer was noted as full causing slow downloads. Consider adding nix.settings.download-buffer-size to hosts to improve large package downloads.


