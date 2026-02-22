{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  user = "kids";
  homeDir = "/home/${user}";
  jellyfinUrl = "https://jellyfin.${domain}";

  # Custom packages
  barely-game-console = import ../../pkgs/barely-game-console { inherit pkgs; };

  # Persistent data paths
  dataDir = "/var/lib/game-console";
  romsDir = "${dataDir}/roms";
  artworkDir = "${dataDir}/assets";
  savesDir = "${dataDir}/saves";
  savestateDir = "${dataDir}/savestates";

  # Libretro core paths
  cores = {
    snes9x = "${pkgs.libretro.snes9x}/lib/retroarch/cores/snes9x_libretro.so";
    nestopia = "${pkgs.libretro.nestopia}/lib/retroarch/cores/nestopia_libretro.so";
    genesis-plus-gx = "${pkgs.libretro.genesis-plus-gx}/lib/retroarch/cores/genesis_plus_gx_libretro.so";
    mupen64plus = "${pkgs.libretro.mupen64plus}/lib/retroarch/cores/mupen64plus_next_libretro.so";
  };

  # Chromium wrapped with kiosk flags (launchable via RFID card)
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

  # RetroArch config
  retroarchCfg = pkgs.writeText "retroarch.cfg" ''
    video_fullscreen = "true"
    video_driver = "vulkan"
    video_vsync = "true"
    video_threaded = "true"
    video_hard_sync = "true"
    video_hard_sync_frames = "1"
    video_smooth = "false"

    audio_driver = "alsa"

    savefile_directory = "${savesDir}"
    savestate_directory = "${savestateDir}"

    menu_show_load_content_animation = "false"
    video_font_enable = "false"
    menu_enable_widgets = "false"
    settings_show_onscreen_display = "false"
    input_overlay_enable = "false"
  '';

  # Card mappings — RFID card ID to game config
  cardMappings = {
    # SNES
    "0005593265" = {
      rom_path = "${romsDir}/snes/Super Mario World (U) [!].zip";
      emulator = cores.snes9x;
      artwork = "assets/SMWCase.jpg";
    };
    "0006405066" = {
      rom_path = "${romsDir}/snes/Harvest Moon (U).zip";
      emulator = cores.snes9x;
      artwork = "assets/harvest-moon.jpg";
    };
    "0006970516" = {
      rom_path = "${romsDir}/snes/Legend of Zelda, The - A Link to the Past (U) [!].zip";
      emulator = cores.snes9x;
      artwork = "assets/zelda-link-to-the-past.jpg";
    };
    "0008241197" = {
      rom_path = "${romsDir}/snes/Sim City (U) [!].zip";
      emulator = cores.snes9x;
      artwork = "assets/sim-city.jpg";
    };
    "0007917398" = {
      rom_path = "${romsDir}/snes/Star Fox (U) (V1.2) [!].zip";
      emulator = cores.snes9x;
      artwork = "assets/star-fox.jpg";
    };
    "0007507355" = {
      rom_path = "${romsDir}/snes/Super Mario RPG - Legend of the Seven Stars (U) [!].zip";
      emulator = cores.snes9x;
      artwork = "assets/super-mario-rpg.png";
    };
    "0007763882" = {
      rom_path = "${romsDir}/snes/Wario's Woods (E).smc";
      emulator = cores.snes9x;
      artwork = "assets/warios-woods.png";
    };
    "0007486482" = {
      rom_path = "${romsDir}/snes/Super Metroid (E) [!].zip";
      emulator = cores.snes9x;
      artwork = "assets/super-metroid.jpg";
    };
    "0007505411" = {
      rom_path = "${romsDir}/snes/Final Fantasy II (USA) (Rev 1).zip";
      emulator = cores.snes9x;
      artwork = "assets/final-fantasy-ii.jpg";
    };
    "0007550190" = {
      rom_path = "${romsDir}/snes/Donkey Kong Country.zip";
      emulator = cores.snes9x;
      artwork = "assets/donkey-kong-country.jpg";
    };

    # NES
    "0007315288" = {
      rom_path = "${romsDir}/nes/Zelda - The Legend of Zelda.zip";
      emulator = cores.nestopia;
      artwork = "assets/zelda.png";
    };
    "0007772848" = {
      rom_path = "${romsDir}/nes/Zelda 2 - The Adventure of Link (U).zip";
      emulator = cores.nestopia;
      artwork = "assets/zelda-adventure-of-link.png";
    };
    "0007542250" = {
      rom_path = "${romsDir}/nes/Final Fantasy (U).zip";
      emulator = cores.nestopia;
      artwork = "assets/final-fantasy.png";
    };

    # Genesis
    "0007569065" = {
      rom_path = "${romsDir}/genesis/Sonic The Hedgehog (USA, Europe).zip";
      emulator = cores.genesis-plus-gx;
      artwork = "assets/sonic.jpg";
    };

    # N64
    "0007741136" = {
      rom_path = "${romsDir}/n64/Super Smash Bros. (U) [!].zip";
      emulator = cores.mupen64plus;
      artwork = "assets/super-smash-bros.jpg";
    };

    # Jellyfin (command card)
    "0007300935" = {
      command = [ "${kioskBrowser}/bin/kiosk-browser" ];
      artwork = "assets/jellyfin.png";
    };
  };

  # Generate config.toml from card mappings
  configToml = let
    mkEntry = cardId: info: let
      lines = lib.optional (info ? rom_path) ''rom_path = "${info.rom_path}"''
           ++ lib.optional (info ? emulator) ''emulator = "${info.emulator}"''
           ++ [ ''artwork = "${info.artwork}"'' ]
           ++ lib.optional (info ? command) ''command = [${lib.concatMapStringsSep ", " (c: ''"${c}"'') info.command}]'';
    in ''
      [rfid_cards."${cardId}"]
      ${lib.concatStringsSep "\n" lines}
    '';
  in pkgs.writeText "config.toml" ''
    [rfid_cards]

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkEntry cardMappings)}
  '';

  # Wrapper: sets up working directory and launches the console app
  gameConsoleLauncher = pkgs.writeShellScriptBin "game-console" ''
    WORKDIR=$(mktemp -d)
    trap "rm -rf $WORKDIR" EXIT

    ln -sf ${configToml} "$WORKDIR/config.toml"
    ln -sf ${retroarchCfg} "$WORKDIR/retroarch.cfg"
    ln -sf ${artworkDir} "$WORKDIR/assets"

    export PATH="${pkgs.retroarch-bare}/bin:$PATH"

    cd "$WORKDIR"
    exec ${barely-game-console}/bin/barely-game-console
  '';

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

  # Cage session: game console replaces chromium as the primary UI
  kioskSession = pkgs.writeShellScriptBin "kiosk-session" ''
    (sleep 2 && ${setupHdmiAudio}/bin/setup-hdmi-audio) &

    export WLR_OUTPUT_SCALE=2
    exec ${pkgs.cage}/bin/cage -s -- ${gameConsoleLauncher}/bin/game-console
  '';
in
{
  # Create the kids user with input group for evdev (RFID reader + power button)
  users.users.${user} = {
    isNormalUser = true;
    home = homeDir;
    hashedPassword = "";
    extraGroups = [ "video" "audio" "render" "input" ];
  };

  # Persist home directory
  environment.persistence."/persist/system".directories = [
    { directory = homeDir; user = user; group = "users"; mode = "0700"; }
  ];

  # Game data directories (ROMs and artwork scp'd manually, saves persist)
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 ${user} users -"
    "d ${romsDir} 0755 ${user} users -"
    "d ${romsDir}/snes 0755 ${user} users -"
    "d ${romsDir}/nes 0755 ${user} users -"
    "d ${romsDir}/genesis 0755 ${user} users -"
    "d ${romsDir}/n64 0755 ${user} users -"
    "d ${artworkDir} 0755 ${user} users -"
    "d ${savesDir} 0755 ${user} users -"
    "d ${savestateDir} 0755 ${user} users -"
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

  # Repurpose power button as select signal for game console
  services.logind.settings.Login.HandlePowerKey = "ignore";

  # Allow empty password login (for auto-login user)
  security.pam.services.greetd.allowNullPassword = true;
}
