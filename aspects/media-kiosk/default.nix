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
  # the classic boot-straight-into-jellyfin behavior is kept. The backend
  # itself is the overlays.chore-galaxy declaration in the host manifest
  # (fort-overlay-manager pipeline, CI-published from infra/chore-galaxy);
  # its overlay.nix runs it as the session user with the session's Wayland
  # env, so apps it spawns land on the cage compositor: cage stacks new
  # fullscreen windows on top and reveals the browser again when they exit —
  # launch/return needs no extra wiring. This aspect owns the session, the
  # seed data, the launchable app packages, and the admin port; keep
  # galaxy.port in sync with the overlay's config.port.
  galaxyPort = toString galaxy.port;
  galaxyDataDir = "/var/lib/chore-galaxy";

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

  # Runs INSIDE the compositor (sway exec): wait (bounded) for the local
  # backend, then a chromium --app window pointed at it — the galaxy is
  # local, so boot does NOT block on jellyfin reachability. If the backend
  # never comes up, fall back to direct jellyfin: a broken galaxy must never
  # strand the kids. (--app, not --kiosk: wayland/ozone ignores kiosk
  # fullscreen flags; an --app window has no toolbar by construction and the
  # compositor forces every window fullscreen anyway. --incognito guards
  # against restore/crash-bubble state; the kiosk holds no client state.)
  kioskBrowser = pkgs.writeShellScriptBin "kiosk-browser" ''
    echo "Waiting for chore-galaxy on 127.0.0.1:${galaxyPort}..."
    for i in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl -sf --max-time 2 "http://127.0.0.1:${galaxyPort}/api/state" >/dev/null 2>&1; then
        echo "Chore Galaxy up — launching kiosk browser"
        exec ${pkgs.chromium}/bin/chromium \
          --ozone-platform=wayland \
          --app="http://127.0.0.1:${galaxyPort}/" \
          --incognito \
          --noerrdialogs \
          --disable-session-crashed-bubble \
          --no-first-run \
          --autoplay-policy=no-user-gesture-required
      fi
      sleep 1
    done
    echo "Chore Galaxy never came up — FALLBACK to direct Jellyfin"
    export QT_QPA_PLATFORM=wayland
    export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
    exec ${pkgs.jellyfin-media-player}/bin/jellyfin-desktop --tv --fullscreen
  '';

  # Sway in kiosk trim, replacing cage: cage never presented SDL/gamescope
  # fullscreen surfaces over chromium (Qt clients were fine — jellyfin,
  # kbreakout — but the games are SDL). Sway's stacking and fullscreen
  # handling are battle-tested, and it brings xwayland as a fallback for
  # stubborn clients. Kiosk-ification: zero keybindings (no way off the
  # couch into a shell), no bar, no borders, every window forced fullscreen
  # — a new window covers the kiosk, closing it reveals the kiosk again:
  # the same contract cage gave us.
  swayConfig = pkgs.writeText "kiosk-sway.conf" ''
    default_border none
    default_floating_border none
    focus_follows_mouse no
    xwayland enable
    seat * hide_cursor 3000
    for_window [all] fullscreen enable
    exec ${kioskBrowser}/bin/kiosk-browser
  '';

  # Galaxy mode boots sway; the classic no-galaxy manifest keeps the
  # original cage-into-jellyfin session untouched.
  kioskSession = pkgs.writeShellScriptBin "kiosk-session" ''
    ${waitForNetwork}/bin/wait-for-network
    ${if galaxy == null then jellyfinDirect else ''
    exec ${pkgs.sway}/bin/sway -c ${swayConfig}''}
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
      # The free starter app: block-breaker, arrow-key + native gamepad.
      lbreakouthd
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

  # The backend service itself is the overlays.chore-galaxy declaration in
  # the host manifest (its overlay.nix carries user/env/health); this aspect
  # provides the data dir + one-time seed (C = copy only if the target does
  # not exist). State stays hand-editable; the backend hot-reloads edits.
  systemd = lib.optionalAttrs (galaxy != null) {
    tmpfiles.rules = [
      "d ${galaxyDataDir} 0755 ${user} users -"
      "C ${galaxyDataDir}/state.json 0644 ${user} users - ${galaxy.stateSeed}"
      "C ${galaxyDataDir}/launchers.json 0644 ${user} users - ${galaxy.launchersSeed}"
    ];
  };
}
