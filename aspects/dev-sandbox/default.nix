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
  opencode = import ../../pkgs/opencode { inherit pkgs; };
  beads = import ../../pkgs/beads { inherit pkgs; };
  ticket = import ../../pkgs/ticket { inherit pkgs; };
  fort = import ../../pkgs/fort { inherit pkgs domain; };
  cursor-agent = import ../../pkgs/cursor-agent { inherit pkgs; };

  # Handler for git-token: extracts token from JSON response and stores it
  # Note: chmod 644 so dev user can read it for git credential helper
  devTokenPath = "/var/lib/fort-git/dev-token";
  gitTokenHandler = pkgs.writeShellScript "git-token-handler" ''
    ${pkgs.coreutils}/bin/mkdir -p /var/lib/fort-git
    ${pkgs.jq}/bin/jq -r '.token' > ${devTokenPath}
    ${pkgs.coreutils}/bin/chmod 644 ${devTokenPath}
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
    zellij
    zsh
    starship
    fzf
    zoxide
    htop

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
    gnumake

    # Go
    go

    # Rust
    rustc
    cargo
    rustfmt
    clippy

    # C/build tools
    gcc
    pkg-config

    # Claude/AI tools
    claude-code
    cursor-agent
    opencode
    beads
    ticket

    # Fort control plane
    fort

    # Calendar
    vdirsyncer
    khal

    # Matrix
    matrix-conduit
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
          tmux attach-session -t "$LAST_SESSION"
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
    # vdirsyncer/khal directories
    "d ${homeDir}/.config/vdirsyncer 0700 ${user} users -"
    "d ${homeDir}/.config/khal 0700 ${user} users -"
    "d ${homeDir}/.local/share/vdirsyncer 0700 ${user} users -"
    "d ${homeDir}/.local/share/vdirsyncer/radicale 0700 ${user} users -"
  ];

  # Request RW git token from forge via control plane
  # Host identity (ratched) is allowed RW access by the git-token capability
  # Stored separately from gitops RO token (dev-token vs deploy-token)
  fort.host.needs.git-token.dev = {
    from = "drhorrible";
    request = { access = "rw"; };
    handler = gitTokenHandler;
  };

  # Agent key for fort signing (readable by dev user)
  age.secrets.dev-sandbox-agent-key = {
    file = ./agent-key.age;
    path = agentKeyPath;
    owner = user;
    group = "users";
    mode = "0600";
  };

  # Radicale password for vdirsyncer (CalDAV sync)
  age.secrets.radicale-password = {
    file = ../../apps/radicale/password.age;
    owner = "root";
    group = "root";
    mode = "0600";
  };

  # Generate vdirsyncer config with secrets at boot
  # Runs as root to read secrets, then chowns to dev
  systemd.services.vdirsyncer-config = {
    description = "Generate vdirsyncer config";
    wantedBy = [ "multi-user.target" ];
    after = [ "agenix.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ coreutils ];
    script = ''
      # Ensure token file is owned by vdirsyncer and group-readable
      if [ -f /var/lib/vdirsyncer/token ]; then
        chown vdirsyncer:vdirsyncer /var/lib/vdirsyncer/token
        chmod 640 /var/lib/vdirsyncer/token
      fi

      # Read secrets (only root can read these)
      CLIENT_ID=$(cat ${config.age.secrets.oauth-client-id.path} | tr -d '\n')
      CLIENT_SECRET=$(cat ${config.age.secrets.oauth-client-secret.path} | tr -d '\n')
      RADICALE_PASSWORD=$(cat ${config.age.secrets.radicale-password.path} | tr -d '\n')

      # Ensure directories exist
      mkdir -p ${homeDir}/.config/vdirsyncer
      mkdir -p ${homeDir}/.config/khal
      mkdir -p ${homeDir}/.local/share/vdirsyncer/status

      cat > ${homeDir}/.config/vdirsyncer/config << EOF
      [general]
      status_path = "${homeDir}/.local/share/vdirsyncer/status/"

      [pair google_calendar]
      a = "google_calendar_remote"
      b = "google_calendar_local"
      collections = ["from a", "from b"]
      metadata = ["color"]

      [storage google_calendar_remote]
      type = "google_calendar"
      token_file = "/var/lib/vdirsyncer/token"
      client_id = "$CLIENT_ID"
      client_secret = "$CLIENT_SECRET"

      [storage google_calendar_local]
      type = "filesystem"
      path = "${homeDir}/.local/share/vdirsyncer/calendars/"
      fileext = ".ics"

      # Radicale CalDAV (personal calendar)
      [pair radicale_calendar]
      a = "radicale_remote"
      b = "radicale_local"
      collections = ["from a", "from b"]
      metadata = ["color"]

      [storage radicale_remote]
      type = "caldav"
      url = "https://calendar.${domain}/kevin/"
      username = "kevin"
      password = "$RADICALE_PASSWORD"

      [storage radicale_local]
      type = "filesystem"
      path = "${homeDir}/.local/share/vdirsyncer/radicale/"
      fileext = ".ics"
      EOF

      chown ${user}:users ${homeDir}/.config/vdirsyncer/config
      chmod 600 ${homeDir}/.config/vdirsyncer/config

      # Generate khal config
      cat > ${homeDir}/.config/khal/config << EOF
      [calendars]

      [[google]]
      path = ${homeDir}/.local/share/vdirsyncer/calendars/*
      type = discover

      [[radicale]]
      path = ${homeDir}/.local/share/vdirsyncer/radicale/*
      type = discover
      color = dark green

      [locale]
      local_timezone = America/Chicago
      default_timezone = America/Chicago
      timeformat = %H:%M
      dateformat = %Y-%m-%d
      longdateformat = %Y-%m-%d
      datetimeformat = %Y-%m-%d %H:%M
      longdatetimeformat = %Y-%m-%d %H:%M

      [default]
      highlight_event_days = True
      default_calendar = personal
      EOF

      chown ${user}:users ${homeDir}/.config/khal/config
      chmod 600 ${homeDir}/.config/khal/config

      # Fix ownership of directories
      chown -R ${user}:users ${homeDir}/.config/vdirsyncer
      chown -R ${user}:users ${homeDir}/.config/khal
      chown -R ${user}:users ${homeDir}/.local/share/vdirsyncer
    '';
  };

  # Bootstrap: run vdirsyncer discover if calendars not yet set up
  systemd.services.vdirsyncer-bootstrap = {
    description = "Initial vdirsyncer calendar discovery";
    after = [ "vdirsyncer-config.service" "network-online.target" ];
    requires = [ "vdirsyncer-config.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = user;
      Group = "vdirsyncer";  # Need vdirsyncer group to read token
    };
    path = with pkgs; [ vdirsyncer ];
    script = ''
      # Skip if already discovered (status dir has content)
      if [ -d "${homeDir}/.local/share/vdirsyncer/status" ] && [ "$(ls -A ${homeDir}/.local/share/vdirsyncer/status 2>/dev/null)" ]; then
        echo "Calendars already discovered, skipping"
        exit 0
      fi

      # Skip if no token yet
      if [ ! -f /var/lib/vdirsyncer/token ]; then
        echo "No OAuth token yet, skipping discovery"
        exit 0
      fi

      echo "Running initial calendar discovery..."
      vdirsyncer discover
      echo "Discovery complete"
    '';
  };

  # Periodic calendar sync (every 15 minutes)
  systemd.timers.vdirsyncer-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "15m";
    };
  };

  systemd.services.vdirsyncer-sync = {
    description = "Sync calendars with Google and Radicale";
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = "vdirsyncer";
    };
    path = with pkgs; [ vdirsyncer coreutils ];
    script = ''
      # Skip if no token yet
      if [ ! -f /var/lib/vdirsyncer/token ]; then
        echo "No OAuth token, skipping sync"
        exit 0
      fi

      vdirsyncer sync

      # Touch marker file for freshness tracking
      touch ${homeDir}/.local/share/vdirsyncer/.last_sync
    '';
  };

  # Daily briefing (12:15 UTC = 6:15am Central during CST, 5:15am during CDT)
  systemd.timers.daily-briefing = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 12:15:00";
      Persistent = true;  # Run if missed while system was off
    };
  };

  systemd.services.daily-briefing = {
    description = "Generate daily briefing";
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = "users";
      WorkingDirectory = "${homeDir}/Projects/exocortex/scripts/daily-briefing";
    };
    environment = {
      HOME = homeDir;
      FORT_SSH_KEY = agentKeyPath;
      FORT_ORIGIN = "dev-sandbox";
    };
    path = devTools ++ [ pkgs.bash ];
    script = ''
      ${homeDir}/Projects/exocortex/scripts/daily-briefing/run.sh
    '';
  };

  # Matrix-Claude bridge
  systemd.services.exo-bridge = {
    description = "Matrix-Claude bridge";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = user;
      Group = "users";
      WorkingDirectory = "${homeDir}/Projects/exocortex";
      Restart = "always";
      RestartSec = "5s";
    };
    environment = {
      HOME = homeDir;
      FORT_SSH_KEY = agentKeyPath;
      FORT_ORIGIN = "dev-sandbox";
    };
    path = devTools ++ [ pkgs.bash ];
    script = ''
      . /etc/set-environment
      export PATH="${homeDir}/.local/bin:$PATH"
      exec ${homeDir}/Projects/exocortex/cmd/exo-bridge/exo-bridge
    '';
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

  # Development services
  fort.cluster.services = [{
    name = "bz";
    port = 6167;
    visibility = "vpn";
    sso.mode = "none";
  }];
}
