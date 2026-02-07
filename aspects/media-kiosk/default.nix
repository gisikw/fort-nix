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

  # Script to find and enable HDMI audio
  setupHdmiAudio = pkgs.writeShellScriptBin "setup-hdmi-audio" ''
    # Wait for PipeWire to be ready
    for i in $(seq 1 10); do
      ${pkgs.wireplumber}/bin/wpctl status &>/dev/null && break
      sleep 0.5
    done

    # Get the card device ID (usually 49, but let's find it dynamically)
    CARD_ID=$(${pkgs.wireplumber}/bin/wpctl status | grep -E "^\s+[0-9]+\. .*\[alsa\]" | head -1 | awk '{print $1}' | tr -d '.')

    if [ -z "$CARD_ID" ]; then
      echo "No ALSA card found"
      exit 0
    fi

    # Try profiles 3-5 which typically have HDMI, find one with a connected HDMI sink
    for profile in 3 4 5; do
      ${pkgs.wireplumber}/bin/wpctl set-profile "$CARD_ID" "$profile" 2>/dev/null
      sleep 0.3

      # Look for an HDMI sink
      HDMI_SINK=$(${pkgs.wireplumber}/bin/wpctl status | grep -E "^\s+[0-9]+\. .*HDMI" | head -1 | awk '{print $1}' | tr -d '.')

      if [ -n "$HDMI_SINK" ]; then
        echo "Found HDMI sink $HDMI_SINK on profile $profile"
        ${pkgs.wireplumber}/bin/wpctl set-default "$HDMI_SINK"
        # Set volume to 100%
        ${pkgs.wireplumber}/bin/wpctl set-volume "$HDMI_SINK" 1.0
        exit 0
      fi
    done

    echo "No HDMI sink found"
  '';

  # Wrapper that sets up audio and display before launching Cage
  kioskSession = pkgs.writeShellScriptBin "kiosk-session" ''
    # Set up HDMI audio in background (Cage needs to start for PipeWire to init)
    (sleep 2 && ${setupHdmiAudio}/bin/setup-hdmi-audio) &

    export WLR_OUTPUT_SCALE=2
    exec ${pkgs.cage}/bin/cage -s -- ${kioskBrowser}/bin/kiosk-browser
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
        command = "${kioskSession}/bin/kiosk-session";
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
