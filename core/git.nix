{ config, lib, pkgs, ... }:

{
  # Dedicated git user — SSH-only access with git-shell
  users.users.git = {
    isSystemUser = true;
    home = "/var/lib/core-git";
    shell = "${pkgs.git}/bin/git-shell";
    group = "git";
    # Master key authorizes provisioning pushes
    # Additional keys (Kevin's FIDO2) can be added here or via authorized_keys file
    openssh.authorizedKeys.keyFiles = [
      /var/lib/core/master-key.pub
    ];
  };
  users.groups.git = {};

  systemd.tmpfiles.rules = [
    "d /var/lib/core-git 0750 git git -"
  ];

  # Initialize bare repo on first boot
  systemd.services.core-git-init = {
    description = "Initialize core bare git repository";
    after = [ "local-fs.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "git";
      Group = "git";
    };
    path = [ pkgs.git ];
    script = ''
      REPO="/var/lib/core-git/fort-nix.git"
      if [ ! -d "$REPO/objects" ]; then
        git init --bare "$REPO"

        # Post-receive hook
        cat > "$REPO/hooks/post-receive" << 'HOOK'
#!/bin/sh
set -eu

while read oldrev newrev refname; do
  branch="''${refname#refs/heads/}"

  if [ "$branch" = "main" ]; then
    echo "==> main updated ($oldrev → $newrev)"

    # 1. Rebuild core itself
    echo "==> Triggering core rebuild..."
    # TODO: nixos-rebuild switch --flake /path/to/checkout

    # 2. Mirror to GitHub (if token exists)
    if [ -f /var/lib/core-git/github-token ]; then
      echo "==> Mirroring to GitHub..."
      cd "$REPO"
      git push --mirror github 2>&1 || echo "  GitHub mirror failed (non-fatal)"
    fi

    # 3. Mirror to Forgejo (if token exists)
    if [ -f /var/lib/core-git/forgejo-token ]; then
      echo "==> Mirroring to Forgejo..."
      cd "$REPO"
      git push --mirror forgejo 2>&1 || echo "  Forgejo mirror failed (non-fatal)"
    fi

    # 4. Fleet deploy
    # TODO: trigger deploy-rs or notify cattle via post-receive
  fi
done
HOOK
        chmod +x "$REPO/hooks/post-receive"

        echo "Bare repo initialized at $REPO"
      fi
    '';
  };
}
