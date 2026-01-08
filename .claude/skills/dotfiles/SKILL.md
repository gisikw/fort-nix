---
name: dotfiles
description: Update home-manager/dotfiles configuration. Use when asked to bump dotfiles, update home-config, refresh home-manager, or similar requests about the dev environment configuration.
---

# Dotfiles / Home-Manager Update

This skill handles updating the home-manager configuration (dotfiles) for the dev-sandbox environment.

## What This Updates

The `home-config` input in the cluster flake (`clusters/bedlam/flake.nix`) points to `github:gisikw/config`, which contains:
- Shell configuration (zsh, starship, etc.)
- Editor configuration (neovim, helix, etc.)
- Git configuration
- Other user environment setup

The dev-sandbox host (ratched) consumes this via the `dev-sandbox` aspect.

## Trigger Phrases

Use this skill when the user asks to:
- "bump dotfiles"
- "update dotfiles"
- "bump home-manager"
- "update home-config"
- "refresh the dev environment config"

## Steps

### 1. Update the cluster flake input

```bash
nix flake update home-config --flake ./clusters/bedlam
```

This updates `clusters/bedlam/flake.lock` with the latest commit from the home-config repo.

### 2. Update ratched's flake lock

```bash
nix flake update --flake ./clusters/bedlam/hosts/ratched
```

**Why?** Even though ratched has `home-config.follows = "cluster/home-config"`, the `follows` directive tells Nix *where* to resolve the input from, but each flake's lock file captures its own resolved state. Ratched's lock needs to be regenerated to pick up the cluster's new home-config.

Note: You cannot use `nix flake update home-config` for ratched because `home-config` is a `follows` directive, not a direct input.

### 3. Commit both lock files

```bash
git add clusters/bedlam/flake.lock clusters/bedlam/hosts/ratched/flake.lock
git commit -m "chore: Bump home-config to <short-sha>"
git push
```

### 4. Deploy ratched

```bash
just deploy ratched
```

This waits for comin to fetch, build, and activate the new configuration. The dev environment will have the updated dotfiles after this completes.

## Verification

After deployment, the user can verify the update by checking that their shell/editor/etc. reflects the expected changes from the home-config repo.
