---
id: fort-cy6.7
status: closed
deps: [fort-cy6.5, fort-cy6.6]
links: []
created: 2025-12-27T23:53:05.370399023Z
type: task
priority: 1
parent: fort-cy6
---
# Create release workflow with secret re-keying

Create the Forgejo Actions workflow that re-keys secrets for host recipients and pushes to the release branch.

## Context
This is the core of the two-branch secrets model:
1. Developer pushes to main (secrets keyed for editors)
2. CI inspects each host's agenix config to determine which secrets it needs
3. CI re-keys those secrets for the host's public key
4. CI pushes to release branch
5. Hosts (via comin) pull from release and can decrypt their secrets

## Implementation

### Create workflow file
Create `.forgejo/workflows/release.yml`:

```yaml
name: Build and Release

on:
  push:
    branches: [main]

jobs:
  release:
    runs-on: nixos
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # Need full history for branch operations

      - name: Determine per-host secrets
        run: |
          mkdir -p /tmp/host-secrets
          for host in $(nix eval .#hosts --json 2>/dev/null | jq -r 'keys[]' || echo ""); do
            echo "Analyzing secrets for $host..."
            nix eval ".#nixosConfigurations.$host.config.age.secrets" --json 2>/dev/null \
              | jq -r 'to_entries[] | .value.file' \
              | sort -u > "/tmp/host-secrets/$host.txt" || echo "No secrets for $host"
          done

      - name: Re-key secrets for recipients
        env:
          FORGE_AGE_KEY: ${{ secrets.FORGE_AGE_KEY }}
        run: |
          echo "$FORGE_AGE_KEY" > /tmp/forge-key.txt
          trap 'rm -f /tmp/forge-key.txt' EXIT
          
          for host in $(ls /tmp/host-secrets/); do
            host="${host%.txt}"
            echo "::group::Re-keying for $host"
            
            hostKey=$(nix eval ".#hosts.$host.device.sshPublicKey" --raw 2>/dev/null || echo "")
            if [ -z "$hostKey" ]; then
              echo "::warning::Could not get key for $host, skipping"
              continue
            fi
            
            while IFS= read -r secret; do
              [ -z "$secret" ] && continue
              echo "Re-keying: $secret"
              # Decrypt with forge key, re-encrypt for host
              age -d -i /tmp/forge-key.txt "$secret" \
                | age -e -r "$hostKey" -o "$secret.new" \
                && mv "$secret.new" "$secret"
            done < "/tmp/host-secrets/$host.txt"
            
            echo "::endgroup::"
          done

      - name: Commit and push release branch
        run: |
          git config user.name "Forge CI"
          git config user.email "forge@fort.gisi.network"
          
          git checkout -B release
          git add -A
          git commit -m "Release: $(git rev-parse --short main) - $(date -Iseconds)" \
            || echo "No changes to commit"
          git push -f origin release
```

### Secrets Required
- `FORGE_AGE_KEY`: Forge's age private key (for decrypting editor-keyed secrets)

Store in Forgejo repository secrets (Settings → Secrets).

### Getting Host List
The workflow assumes `.#hosts` exports a list of hosts. This may need adjustment based on flake structure. Alternative:
```bash
ls clusters/bedlam/hosts/
```

### Getting Host Public Keys
Assumes `.#hosts.$host.device.sshPublicKey` is accessible. May need to expose this in the flake or read from device manifest files.

## Acceptance Criteria
- [ ] Workflow triggers on push to main
- [ ] Release branch is created/updated
- [ ] Secrets in release branch are keyed for correct hosts
- [ ] Forge can still decrypt secrets on main branch
- [ ] Hosts can decrypt their secrets on release branch

## Dependencies
- fort-cy6.5: Check workflow should pass first
- fort-cy6.6: Secrets must be refactored to editor-only

## Security Considerations
- FORGE_AGE_KEY is highly sensitive - it can decrypt all secrets
- Stored only in Forgejo secrets, never in repo
- Runner should not log secret contents

## Notes
- The exact nix eval paths may need adjustment based on flake structure
- Consider adding the build step here once Attic is set up (Phase 3)
- May want to add a "dry-run" mode for testing


