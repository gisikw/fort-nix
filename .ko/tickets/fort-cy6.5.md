---
id: fort-cy6.5
status: closed
deps: [fort-cy6.4, fort-cy6.3]
links: []
created: 2025-12-27T23:50:33.356495967Z
type: task
priority: 2
parent: fort-cy6
---
# Create flake check CI workflow

Create a Forgejo Actions workflow that runs `nix flake check` on pull requests and pushes.

## Context
This is the basic CI validation workflow. It ensures the flake evaluates correctly before changes are merged.

## Implementation

### Create workflow file
Create `.forgejo/workflows/check.yml`:

```yaml
name: Flake Check

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  check:
    runs-on: nixos
    steps:
      - uses: actions/checkout@v4

      - name: Check root flake
        run: nix flake check --no-build

      - name: Check host flakes
        run: |
          for host_dir in clusters/bedlam/hosts/*/; do
            host=$(basename "$host_dir")
            echo "::group::Checking host: $host"
            nix flake check "$host_dir" --no-build
            echo "::endgroup::"
          done

      - name: Check device flakes
        run: |
          for device_dir in clusters/bedlam/devices/*/; do
            device=$(basename "$device_dir")
            echo "::group::Checking device: $device"
            nix flake check "$device_dir" --no-build
            echo "::endgroup::"
          done
```

### Notes on `--no-build`
Using `--no-build` speeds up checks by only evaluating, not building. Full builds happen in the release workflow.

### Runner Requirements
- Runner must have Nix with flakes enabled
- Uses `nixos` label to run on host runner

## Acceptance Criteria
- [ ] Workflow triggers on push to main
- [ ] Workflow triggers on PRs to main
- [ ] All flake checks pass on current main
- [ ] Failed checks block PR merge (once branch protection configured)

## Dependencies
- fort-cy6.4: Runner must be set up
- fort-cy6.3: Repo must be in Forgejo

## Notes
- This mirrors `just test` functionality
- Consider caching Nix store between runs for speed


