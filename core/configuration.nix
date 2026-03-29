{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware.nix
    ./router.nix
    ./dns.nix
    ./git.nix
    ./http.nix
    ./enroll.nix
    ./headscale.nix
    ./ip-watchdog.nix
  ];

  # Cluster identity
  # The domain is the cluster's DNS namespace. Changing it means a new cluster.
  networking.hostName = "core";
  networking.domain = "weyr.dev";

  time.timeZone = "America/Chicago";

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # SSH — FIDO2 keys only, LAN interface only
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  users.users.root = {
    openssh.authorizedKeys.keys = [
      # FIDO2 public key(s) — baked into ISO at build time
      # Primary YubiKey:
      # "sk-ssh-ed25519@openssh.com AAAA..."
      # Backup YubiKey:
      # "sk-ssh-ed25519@openssh.com AAAA..."
    ];
    # hunter2: for child-proofing, not security
    hashedPassword = "$y$j9T$placeholder$placeholder";
  };

  # Console auto-login — physical access IS the authentication
  services.getty.autologinUser = "root";

  # Firewall is managed by nftables in router.nix
  networking.firewall.enable = false;

  # Core identity secrets — written by install.sh, not managed by nix
  # /var/lib/core/master-key       — SSH private key (provisioning authority)
  # /var/lib/core/master-key.pub   — SSH public key
  # /var/lib/core/registrar.env    — Porkbun API credentials
  # /var/lib/core/wan-ip           — Current WAN IP (written by ip-watchdog)
  systemd.tmpfiles.rules = [
    "d /var/lib/core 0700 root root -"
  ];

  environment.systemPackages = with pkgs; [
    git
    curl
    jq
    htop
    tmux
  ];

  system.stateVersion = "24.11";
}
