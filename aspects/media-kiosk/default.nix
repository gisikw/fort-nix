{ rootManifest, deviceProfileManifest, ... }:
{ config, lib, pkgs, ... }:
if (deviceProfileManifest.platform or "nixos") != "nixos" then
  throw "fort-nix: aspect 'media-kiosk' is Linux-only (greetd/pipewire Linux desktop stack); remove it from this darwin host's manifest"
else
let
  domain = rootManifest.fortConfig.settings.domain;
  user = "kids";
  homeDir = "/home/${user}";
  jellyfinUrl = "https://jellyfin.${domain}";

  # Wait for Tailscale mesh + DNS resolution before launching browser
  waitForNetwork = pkgs.writeShellScriptBin "wait-for-network" ''
    echo "Waiting for Tailscale..."
    for i in $(seq 1 60); do
      if ${pkgs.tailscale}/bin/tailscale status &>/dev/null; then
        echo "Tailscale connected"
        break
      fi
      sleep 1
    done

    echo "Waiting for ${jellyfinUrl} to be reachable..."
    for i in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl -sf --max-time 3 "${jellyfinUrl}" >/dev/null 2>&1; then
        echo "Jellyfin reachable"
        exit 0
      fi
      sleep 1
    done
    echo "Jellyfin timeout — launching anyway"
  '';

  # Cage session: straight into Jellyfin Media Player (TV mode)
  kioskSession = pkgs.writeShellScriptBin "kiosk-session" ''
    ${waitForNetwork}/bin/wait-for-network

    export QT_QPA_PLATFORM=wayland
    export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
    exec ${pkgs.cage}/bin/cage -s -- ${pkgs.jellyfin-media-player}/bin/jellyfin-desktop \
      --tv \
      --fullscreen
  '';
in
{
  users.users.${user} = {
    isNormalUser = true;
    home = homeDir;
    hashedPassword = "";
    extraGroups = [ "video" "audio" "render" "input" ];
  };

  # Persist home directory (JMP config, jellyfin session)
  environment.persistence."/persist/system".directories = [
    { directory = homeDir; user = user; group = "users"; mode = "0700"; }
  ];

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
}
