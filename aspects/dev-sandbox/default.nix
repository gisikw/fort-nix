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

  # Transform script for git-token: extracts token from JSON response
  gitTokenTransform = pkgs.writeShellScript "git-token-transform" ''
    # $1 = store path, stdin = {"token": "...", "username": "..."}
    store_path="$1"
    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$store_path")"
    ${pkgs.jq}/bin/jq -r '.token' > "$store_path"
    ${pkgs.coreutils}/bin/chmod 644 "$store_path"
  '';

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
        # Inject Monokai Pro Spectrum colors via OSC escape sequences
        # Must happen BEFORE tmux attaches, so xterm.js receives them directly
        # OSC 10=fg, 11=bg, 12=cursor, 4;n=ANSI color n
        printf '\e]10;#f7f1ff\a\e]11;#222222\a\e]12;#bab6c0\a'
        printf '\e]4;0;#222222\a\e]4;1;#fc618d\a\e]4;2;#7bd88f\a\e]4;3;#fce566\a'
        printf '\e]4;4;#fd9353\a\e]4;5;#948ae3\a\e]4;6;#5ad4e6\a\e]4;7;#f7f1ff\a'
        printf '\e]4;8;#69676c\a\e]4;9;#fc618d\a\e]4;10;#7bd88f\a\e]4;11;#fce566\a'
        printf '\e]4;12;#fd9353\a\e]4;13;#948ae3\a\e]4;14;#5ad4e6\a\e]4;15;#f7f1ff\a'

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
  # Mode 0710 ensures ACL mask includes execute bit (needed for silverbullet traversal)
  environment.persistence."/persist/system".directories = [
    { directory = homeDir; user = user; group = "users"; mode = "0710"; }
  ];

  # Create Projects directory structure
  # Mode 0710 on homeDir ensures ACL mask includes execute bit
  systemd.tmpfiles.rules = [
    "d ${homeDir} 0710 ${user} users -"
    "d ${homeDir}/.ssh 0700 ${user} users -"
    "d ${homeDir}/Projects 0755 ${user} users -"
    "d /var/lib/fort/dev-sandbox 0755 ${user} users -"
    "d /var/lib/fort-git 0755 root root -"
  ];

  # Request RW git token from forge via control plane
  # Uses dev-sandbox principal identity for RW access
  # Stored separately from gitops RO token (dev-token vs deploy-token)
  fort.host.needs.git-token.dev = {
    providers = [ "drhorrible" ];
    request = { access = "rw"; };
    store = "/var/lib/fort-git/dev-token";
    transform = gitTokenTransform;
    identity = {
      origin = "dev-sandbox";
      keyPath = agentKeyPath;
    };
  };

  # Agent key for fort-agent-call signing (readable by dev user)
  age.secrets.dev-sandbox-agent-key = {
    file = ./agent-key.age;
    path = agentKeyPath;
    owner = user;
    group = "users";
    mode = "0600";
  };

  # Git credential helper for Forgejo access
  # Prefers RW dev-token, falls back to RO deploy-token
  environment.etc."fort-git-credential-helper".source = pkgs.writeShellScript "fort-git-credential-helper" ''
    # Git credential helper - only respond to "get" action
    case "$1" in
      get)
        # Prefer RW token (dev-sandbox), fallback to RO token (gitops)
        if [ -s "/var/lib/fort-git/dev-token" ]; then
          TOKEN=$(cat "/var/lib/fort-git/dev-token")
        elif [ -s "/var/lib/fort-git/deploy-token" ]; then
          TOKEN=$(cat "/var/lib/fort-git/deploy-token")
        else
          exit 0
        fi
        echo "username=forge-admin"
        echo "password=$TOKEN"
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
