{ config, lib, pkgs, coreSystem, ... }:

{
  isoImage.isoBaseName = "core-installer";

  # Include the pre-built core system closure in the ISO
  # install.sh uses this to run nixos-install --system without building on target
  environment.etc."core-system".source = coreSystem;

  environment.systemPackages = with pkgs; [
    git
    parted
    dosfstools
    e2fsprogs
  ];

  # Auto-login — the installer IS the interface
  services.getty.autologinUser = "root";

  # Show banner and prompt on first tty login
  programs.bash.loginShellInit = ''
    if [ "$(tty)" = "/dev/tty1" ] && [ ! -f /tmp/.install-started ]; then
      touch /tmp/.install-started
      echo ""
      echo "╔════════════════════════════════════════════════╗"
      echo "║  Core Box Installer                            ║"
      echo "║                                                ║"
      echo "║  This will:                                    ║"
      echo "║    1. Install NixOS to NVMe                    ║"
      echo "║    2. Copy secrets from USB                    ║"
      echo "║    3. WIPE this USB drive                      ║"
      echo "║                                                ║"
      echo "║  Press Enter to begin, or Ctrl-C to abort.     ║"
      echo "╚════════════════════════════════════════════════╝"
      echo ""
      read -r
      /etc/core-install.sh
    fi
  '';

  environment.etc."core-install.sh" = {
    mode = "0755";
    source = ./install.sh;
  };
}
