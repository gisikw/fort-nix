{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  user = "kids";
  homeDir = "/home/${user}";
  jellyfinUrl = "https://jellyfin.${domain}";

  # Script to find and enable HDMI audio
  setupHdmiAudio = pkgs.writeShellScriptBin "setup-hdmi-audio" ''
    for i in $(seq 1 10); do
      ${pkgs.wireplumber}/bin/wpctl status &>/dev/null && break
      sleep 0.5
    done

    CARD_ID=$(${pkgs.wireplumber}/bin/wpctl status | grep -E "^\s+[0-9]+\. .*\[alsa\]" | head -1 | awk '{print $1}' | tr -d '.')

    if [ -z "$CARD_ID" ]; then
      echo "No ALSA card found"
      exit 0
    fi

    for profile in 3 4 5; do
      ${pkgs.wireplumber}/bin/wpctl set-profile "$CARD_ID" "$profile" 2>/dev/null
      sleep 0.3

      HDMI_SINK=$(${pkgs.wireplumber}/bin/wpctl status | grep -E "^\s+[0-9]+\. .*HDMI" | head -1 | awk '{print $1}' | tr -d '.')

      if [ -n "$HDMI_SINK" ]; then
        echo "Found HDMI sink $HDMI_SINK on profile $profile"
        ${pkgs.wireplumber}/bin/wpctl set-default "$HDMI_SINK"
        ${pkgs.wireplumber}/bin/wpctl set-volume "$HDMI_SINK" 1.0
        exit 0
      fi
    done

    echo "No HDMI sink found"
  '';

  # Cage session: straight into Jellyfin kiosk browser
  kioskSession = pkgs.writeShellScriptBin "kiosk-session" ''
    (sleep 2 && ${setupHdmiAudio}/bin/setup-hdmi-audio) &

    export WLR_OUTPUT_SCALE=2
    exec ${pkgs.cage}/bin/cage -s -- ${pkgs.chromium}/bin/chromium \
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
  users.users.${user} = {
    isNormalUser = true;
    home = homeDir;
    hashedPassword = "";
    extraGroups = [ "video" "audio" "render" ];
  };

  # Persist home directory (chromium profile, jellyfin session)
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
