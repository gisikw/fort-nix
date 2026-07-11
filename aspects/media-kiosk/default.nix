{ rootManifest, galaxy ? null, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  user = "kids";
  homeDir = "/home/${user}";
  jellyfinUrl = "https://jellyfin.${domain}";

  # ── Chore Galaxy (optional) ────────────────────────────────────────────────
  # galaxy = { port = 8600; stateSeed = ./…/state.json; launchersSeed = ./…; }
  # When set, the TV boots into the chore-galaxy kiosk frontend (chromium in
  # cage) and jellyfin becomes an app the galaxy backend launches; when null,
  # the classic boot-straight-into-jellyfin behavior is kept. The backend runs
  # as the session user with the session's Wayland env, so apps it spawns land
  # on the cage compositor: cage stacks new fullscreen windows on top and
  # reveals the browser again when they exit — launch/return needs no extra
  # wiring. Source is vendored (chore-galaxy-src/VENDORED.md): the target
  # shape is the overlay-manager pipeline once the forge repo exists.
  galaxyPort = toString galaxy.port;
  galaxyDataDir = "/var/lib/chore-galaxy";
  chore-galaxy = pkgs.buildGoModule {
    pname = "chore-galaxy";
    version = "0.1.0-45b3886";
    src = ./chore-galaxy-src;
    vendorHash = null; # stdlib only
  };

  # Wait for the Tailscale mesh before launching the surface. Bounded: the TV
  # must come up (possibly degraded) even with no network.
  waitForNetwork = pkgs.writeShellScriptBin "wait-for-network" ''
    echo "Waiting for Tailscale..."
    for i in $(seq 1 60); do
      if ${pkgs.tailscale}/bin/tailscale status &>/dev/null; then
        echo "Tailscale connected"
        break
      fi
      sleep 1
    done
  '';

  jellyfinDirect = ''
    echo "Waiting for ${jellyfinUrl} to be reachable..."
    for i in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl -sf --max-time 3 "${jellyfinUrl}" >/dev/null 2>&1; then
        echo "Jellyfin reachable"
        break
      fi
      sleep 1
      [ "$i" = 60 ] && echo "Jellyfin timeout — launching anyway"
    done
    export QT_QPA_PLATFORM=wayland
    export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
    exec ${pkgs.cage}/bin/cage -s -- ${pkgs.jellyfin-media-player}/bin/jellyfin-desktop \
      --tv \
      --fullscreen
  '';

  # Cage session. Galaxy mode: wait (bounded) for the local backend, then a
  # chromium kiosk pointed at it — the galaxy is local, so boot does NOT block
  # on jellyfin reachability. If the backend never comes up, fall back to
  # direct jellyfin: a broken galaxy must never strand the kids.
  kioskSession = pkgs.writeShellScriptBin "kiosk-session" ''
    ${waitForNetwork}/bin/wait-for-network
    ${if galaxy == null then jellyfinDirect else ''
    echo "Waiting for chore-galaxy on 127.0.0.1:${galaxyPort}..."
    for i in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl -sf --max-time 2 "http://127.0.0.1:${galaxyPort}/api/state" >/dev/null 2>&1; then
        echo "Chore Galaxy up — launching kiosk browser"
        # --incognito: greetd restarts kill chromium uncleanly, and crash-
        # session restore reopens a normal toolbar window that defeats
        # --kiosk. Incognito never restores (the kiosk holds no client
        # state — it re-renders from the SSE stream).
        exec ${pkgs.cage}/bin/cage -s -- ${pkgs.chromium}/bin/chromium \
          --ozone-platform=wayland \
          --kiosk \
          --start-fullscreen \
          --incognito \
          --noerrdialogs \
          --disable-session-crashed-bubble \
          --no-first-run \
          --autoplay-policy=no-user-gesture-required \
          "http://127.0.0.1:${galaxyPort}/"
      fi
      sleep 1
    done
    echo "Chore Galaxy never came up — FALLBACK to direct Jellyfin"
    ${jellyfinDirect}''}
  '';
in
{
  users.users.${user} = {
    isNormalUser = true;
    # Pinned to the uid the host already has: the chore-galaxy service points
    # launched apps at this user's runtime dir (/run/user/1000).
    uid = 1000;
    home = homeDir;
    hashedPassword = "";
    extraGroups = [ "video" "audio" "render" "input" ];
  };

  environment = {
    # Persist home directory (JMP config, jellyfin session, chromium profile)
    persistence."/persist/system".directories = [
      { directory = homeDir; user = user; group = "users"; mode = "0700"; }
    ];
    # Launchable apps live at stable /run/current-system paths so hand-edited
    # launchers.json entries survive nixpkgs bumps and store GC.
    systemPackages = lib.optionals (galaxy != null) (with pkgs; [
      jellyfin-media-player
      superTux
      superTuxKart
      tuxpaint
    ]);
  };

  # greetd for auto-login to Cage session
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${kioskSession}/bin/kiosk-session";
        user = user;
      };
    };
  };

  # GPU and graphics (intel media driver for hardware video decoding)
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-compute-runtime
      mesa
    ];
  };

  # Audio
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Fonts for browser rendering
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-color-emoji
  ];

  # Allow empty password login (for auto-login user)
  security.pam.services.greetd.allowNullPassword = true;

  # Parent admin surface (/admin/) is reached over the mesh at this port.
  networking.firewall.allowedTCPPorts = lib.optionals (galaxy != null) [ galaxy.port ];

  systemd = lib.optionalAttrs (galaxy != null) {
    services.chore-galaxy = {
      description = "Chore Galaxy kiosk backend + launcher";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      # Launcher argv entries use absolute /run/current-system/sw/bin paths,
      # but keep it on PATH too for hand-edited relative entries.
      path = [ chore-galaxy "/run/current-system/sw" ];
      serviceConfig = {
        ExecStart = "${chore-galaxy}/bin/chore-galaxy serve --port ${galaxyPort} --data ${galaxyDataDir}";
        User = user;
        Group = "users";
        WorkingDirectory = galaxyDataDir;
        Restart = "on-failure";
        RestartSec = 5;
        # Launched games run in their own session (Setsid) but stay in this
        # cgroup; KillMode=process keeps a backend restart/redeploy from
        # killing a game mid-play (crash-only both ways — chore-galaxy WORKLOG).
        KillMode = "process";
      };
      environment = {
        # Launched children inherit these and connect to the kiosk session's
        # cage compositor: same user, same runtime dir.
        XDG_RUNTIME_DIR = "/run/user/1000";
        WAYLAND_DISPLAY = "wayland-0";
        QT_QPA_PLATFORM = "wayland";
        QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
        SDL_VIDEODRIVER = "wayland,x11";
      };
    };

    # Data dir + one-time seed (C = copy only if the target does not exist).
    # State stays hand-editable on the host; the backend hot-reloads edits.
    tmpfiles.rules = [
      "d ${galaxyDataDir} 0755 ${user} users -"
      "C ${galaxyDataDir}/state.json 0644 ${user} users - ${galaxy.stateSeed}"
      "C ${galaxyDataDir}/launchers.json 0644 ${user} users - ${galaxy.launchersSeed}"
    ];
  };
}
