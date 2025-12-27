{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  user = "dev";
  homeDir = "/home/${user}";

  # Custom packages
  claude-code = import ../../pkgs/claude-code { inherit pkgs; };
  beads = import ../../pkgs/beads { inherit pkgs; };

  # Core development tools
  devTools = with pkgs; [
    # Version control
    git
    gh

    # Editors
    neovim

    # Shell/terminal
    tmux
    zsh
    starship
    fzf
    zoxide

    # Search/navigation
    ripgrep
    fd
    eza
    bat
    jq
    yq

    # Network
    curl
    wget
    httpie

    # Nix development
    direnv
    nix-direnv

    # Claude/AI tools
    claude-code
    beads
  ];

  # Public key for SSH access
  devPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILjnWniCp8wmg2JzxbWDv5MLEZtdMJqqszZ0F3slNoAF dev@ratched.fort";
in
{
  # Create the dev user
  users.users.${user} = {
    isNormalUser = true;
    home = homeDir;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      devPubKey
    ] ++ rootManifest.fortConfig.settings.authorizedDeployKeys;
  };

  # SSH private key for the dev user (for git operations, etc.)
  age.secrets.dev-ssh-key = {
    file = ./dev-ssh-key.age;
    owner = user;
    mode = "0400";
    path = "${homeDir}/.ssh/id_ed25519";
  };

  # Install dev tools system-wide
  environment.systemPackages = devTools;

  # Enable zsh
  programs.zsh.enable = true;

  # Enable direnv with nix-direnv integration
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Persist the home directory across reboots (for impermanent systems)
  environment.persistence."/persist/system".directories = [
    { directory = homeDir; user = user; group = "users"; mode = "0700"; }
  ];

  # Create Projects directory structure
  systemd.tmpfiles.rules = [
    "d ${homeDir} 0700 ${user} users -"
    "d ${homeDir}/.ssh 0700 ${user} users -"
    "d ${homeDir}/Projects 0755 ${user} users -"
  ];

  # Basic shell configuration for dev user
  system.activationScripts.devUserConfig = ''
    # Create .ssh/config if it doesn't exist
    if [ ! -f ${homeDir}/.ssh/config ]; then
      cat > ${homeDir}/.ssh/config << 'EOF'
Host github.com
  IdentityFile ~/.ssh/id_ed25519
  User git

Host *.fort.${domain}
  IdentityFile ~/.ssh/id_ed25519
EOF
      chown ${user}:users ${homeDir}/.ssh/config
      chmod 600 ${homeDir}/.ssh/config
    fi

    # Create public key file
    echo "${devPubKey}" > ${homeDir}/.ssh/id_ed25519.pub
    chown ${user}:users ${homeDir}/.ssh/id_ed25519.pub
    chmod 644 ${homeDir}/.ssh/id_ed25519.pub
  '';
}
