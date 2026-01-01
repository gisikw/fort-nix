{ rootManifest, extraInputs ? {}, accessKeys ? [], ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  settings = rootManifest.fortConfig.settings;
  user = "dev";

  # Cluster-specific inputs (available when passed from host flake)
  home-config = extraInputs.home-config or null;
  hasHomeConfig = home-config != null;
  homeDir = "/home/${user}";
  agentKeyPath = "/var/lib/fort/dev-sandbox/agent-key";

  # Custom packages
  claude-code = import ../../pkgs/claude-code { inherit pkgs; };
  beads = import ../../pkgs/beads { inherit pkgs; };
  fort-agent-call = import ../../pkgs/fort-agent-call { inherit pkgs domain; };

  # Derive SSH keys for dev-sandbox access from principals
  isSSHKey = k: builtins.substring 0 4 k == "ssh-";
  principalsWithDevSandbox = builtins.filter
    (p: builtins.elem "dev-sandbox" (p.roles or [ ]))
    (builtins.attrValues settings.principals);
  devAuthorizedKeys = builtins.filter isSSHKey (map (p: p.publicKey) principalsWithDevSandbox);

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

    # Crypto/secrets
    openssl
    age

    # Nix development
    direnv
    nix-direnv
    just

    # Claude/AI tools
    claude-code
    beads

    # Fort control plane
    fort-agent-call
  ];
in
{
  # Import home-manager NixOS module when home-config is available
  imports = lib.optionals hasHomeConfig [
    home-config.inputs.home-manager.nixosModules.home-manager
  ];

  # Home-manager configuration for the dev user
  home-manager = lib.mkIf hasHomeConfig {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "bak";
    extraSpecialArgs = {
      isDarwin = false;
      isLinux = true;
    };
    users.${user} = {
      imports = [ home-config.homeManagerModules.default ];
      home.stateVersion = "25.11";
    };
  };

  # Create the dev user
  users.users.${user} = {
    isNormalUser = true;
    home = homeDir;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = devAuthorizedKeys ++ accessKeys;
  };

  # Install dev tools system-wide
  environment.systemPackages = devTools;

  # Enable zsh with tmux auto-attach
  programs.zsh = {
    enable = true;
    interactiveShellInit = ''
      # Auto-attach to tmux on SSH connection
      # Skip if: already in tmux, not interactive, not SSH session
      if [[ -z "$TMUX" && -n "$SSH_CONNECTION" && $- == *i* ]]; then
        # Attach to the most recently used session (by last_attached timestamp)
        LAST_SESSION=$(tmux list-sessions -F '#{session_last_attached} #{session_name}' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        if [[ -n "$LAST_SESSION" ]]; then
          exec tmux attach-session -t "$LAST_SESSION"
        fi
      fi

      # Fort agent configuration for dev-sandbox identity
      export FORT_SSH_KEY="${agentKeyPath}"
      export FORT_ORIGIN="dev-sandbox"
    '';
  };

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
    "d /var/lib/fort/dev-sandbox 0755 ${user} users -"
  ];

  # Agent key for fort-agent-call signing (readable by dev user)
  age.secrets.dev-sandbox-agent-key = {
    file = ./agent-key.age;
    path = agentKeyPath;
    owner = user;
    group = "users";
    mode = "0600";
  };

  # Git credential helper for Forgejo access
  # Reads the token distributed by forgejo-deploy-token-sync
  environment.etc."fort-git-credential-helper".source = pkgs.writeShellScript "fort-git-credential-helper" ''
    # Git credential helper - only respond to "get" action
    case "$1" in
      get)
        TOKEN_FILE="/var/lib/fort-git/forge-token"
        if [ -s "$TOKEN_FILE" ]; then
          echo "username=forge-admin"
          echo "password=$(cat "$TOKEN_FILE")"
        fi
        ;;
    esac
  '';

  # Configure git to use the credential helper for the forge
  programs.git = {
    enable = true;
    config = {
      credential."https://git.${domain}" = {
        helper = "/etc/fort-git-credential-helper";
      };
      # Safe directory for the infra repo
      safe.directory = "${homeDir}/Projects/fort-nix";
    };
  };
}
