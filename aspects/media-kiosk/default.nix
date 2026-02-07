{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  user = "kids";
  homeDir = "/home/${user}";
  jellyfinUrl = "https://jellyfin.${domain}";

  # Chromium wrapped with kiosk flags
  kioskBrowser = pkgs.writeShellScriptBin "kiosk-browser" ''
    exec ${pkgs.chromium}/bin/chromium \
      --kiosk \
      --no-first-run \
      --disable-translate \
      --disable-infobars \
      --disable-suggestions-service \
      --disable-save-password-bubble \
      --disable-session-crashed-bubble \
      --noerrdialogs \
      --disable-features=TranslateUI \
      --autoplay-policy=no-user-gesture-required \
      "${jellyfinUrl}"
  '';
in
{
  # Create the kids user (no password, auto-login only)
  users.users.${user} = {
    isNormalUser = true;
    home = homeDir;
    # No password - only accessible via auto-login at console
    hashedPassword = "";
    extraGroups = [ "video" "audio" "render" ];
  };

  # Persist home directory for any Jellyfin/browser state
  environment.persistence."/persist/system".directories = [
    { directory = homeDir; user = user; group = "users"; mode = "0700"; }
  ];

  # greetd for auto-login to Cage session
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.cage}/bin/cage -s -- ${kioskBrowser}/bin/kiosk-browser";
        user = user;
      };
    };
  };

  # GPU and graphics support
  hardware.graphics.enable = true;

  # Audio support for media playback
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
