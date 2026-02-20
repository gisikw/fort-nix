---
id: fort-23j
status: closed
deps: []
links: []
created: 2026-01-08T12:42:54.163979662Z
type: task
priority: 2
---
# Fix Termix mobile theme/font support

## Background
fort-twh added Monokai Pro Spectrum theme and ProggyClean Nerd Font to Termix via container startup patching. Desktop works perfectly, mobile does not.

## What's Working (Desktop)
- Theme dropdown shows "Monokai Pro Spectrum"
- Font dropdown shows "ProggyClean Nerd Font" (first in list)
- Colors apply correctly (directories are orange #fd9353)

## What's Broken (Mobile)
- Theme selected on desktop doesn't apply colors on mobile
- Directories show default blue (#729fcf) instead of orange (#fd9353)
- CSS shows: `.xterm-fg-12 { color: #729fcf; }` instead of `#fd9353`

## Current Patching (apps/termix/default.nix)
Container startup script patches /app/html/assets/index-ByvOA9sR.js:
1. Adds ProggyClean to TERMINAL_FONTS array (before Caskaydia)
2. Adds @font-face CSS for ProggyClean
3. Adds monokaiProSpectrum to TERMINAL_THEMES object (after dracula)

Uses global regex to catch all instances - but only finds 1 dracula instance.

## Investigation Findings
- Only 1 JS chunk contains theme data (index-ByvOA9sR.js)
- Source code shows mobile Terminal.tsx has HARDCODED theme colors (just bg/fg)
- Mobile imports TERMINAL_THEMES but never uses it for lookup
- Desktop uses `TERMINAL_THEMES[config.theme]?.colors` - mobile doesn't
- #729fcf is "Termix Dark" default brightBlue - confirms fallback

## Contradiction
User reports pre-existing themes (Dracula, Solarized) DO work on mobile with full ANSI colors. Source code suggests they shouldn't. Possibilities:
1. Docker image differs from GitHub source
2. There's a code path not found in source analysis
3. User observation needs verification

## Next Steps
1. Have user verify: does Dracula on mobile show purple (#bd93f9) or default blue (#729fcf)?
2. If mobile truly is hardcoded, consider patching hardcoded color values directly
3. If there's a hidden code path, find and patch it

## Related
- fort-1mb: Admin password lockout issue (separate problem discovered during this work)


