rec {
  hostName = "robotnik";
  device = "c6e75505-6f53-11f0-a531-38a746309e63";

  roles = [ ];

  apps = [ ];

  aspects = [ "observable" ];

  module =
    { config, pkgs, lib, ... }:
    let
      factorioVersion = "2.0.73";

      factorio-wrapper = pkgs.buildFHSEnv {
        name = "factorio";
        targetPkgs =
          pkgs: with pkgs; [
            alsa-lib
            libGL
            xorg.libICE
            xorg.libSM
            xorg.libX11
            xorg.libXcursor
            xorg.libXext
            xorg.libXi
            xorg.libXinerama
            xorg.libXrandr
            libpulseaudio
            libxkbcommon
            wayland
          ];
        runScript = "/var/lib/factorio/factorio/bin/x64/factorio";
      };
    in
    {
      config.fort.host = { inherit roles apps aspects; };

      config.sops.secrets.grimshuk-password = {
        sopsFile = ./grimshuk-password.sops;
        format = "binary";
        neededForUsers = true;
      };

      config.sops.secrets.factorio-username = {
        sopsFile = ./factorio-username.sops;
        format = "binary";
      };

      config.sops.secrets.factorio-token = {
        sopsFile = ./factorio-token.sops;
        format = "binary";
      };

      config.users.users.grimshuk = {
        isNormalUser = true;
        description = "Grimshuk";
        hashedPasswordFile = config.sops.secrets.grimshuk-password.path;
        extraGroups = [ "wheel" "video" "audio" "networkmanager" ];
      };

      # Desktop environment
      config.services.xserver.enable = true;
      config.services.displayManager.gdm.enable = true;
      config.services.desktopManager.gnome.enable = true;

      # Audio
      config.services.pipewire = {
        enable = true;
        alsa.enable = true;
        pulse.enable = true;
      };

      # Factorio Space Age — runtime reconciler
      config.systemd.tmpfiles.rules = [
        "d /var/lib/factorio 0755 root root -"
      ];

      config.systemd.services.factorio-fetch = {
        description = "Download and install Factorio Space Age";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredential = [
            "username:${config.sops.secrets.factorio-username.path}"
            "token:${config.sops.secrets.factorio-token.path}"
          ];
        };
        path = with pkgs; [
          curl
          gnutar
          xz
        ];
        script = ''
          set -euo pipefail
          VERSION="${factorioVersion}"
          INSTALL_DIR="/var/lib/factorio"
          CRED_DIR="/run/credentials/factorio-fetch.service"

          # Skip if already installed at this version
          if [ -f "$INSTALL_DIR/.version" ] && [ "$(cat "$INSTALL_DIR/.version")" = "$VERSION" ]; then
            echo "Factorio $VERSION already installed, skipping"
            exit 0
          fi

          USERNAME=$(tr -d '\n' < "$CRED_DIR/username")
          TOKEN=$(tr -d '\n' < "$CRED_DIR/token")

          echo "Downloading Factorio Space Age $VERSION..."
          TARBALL="$INSTALL_DIR/.download.tar.xz"
          trap 'rm -f "$TARBALL"' EXIT

          curl -sfL \
            --get \
            --data-urlencode "username=$USERNAME" \
            --data-urlencode "token=$TOKEN" \
            "https://factorio.com/get-download/$VERSION/expansion/linux64" \
            -o "$TARBALL"

          echo "Extracting to $INSTALL_DIR..."
          rm -rf "$INSTALL_DIR/factorio"
          tar xf "$TARBALL" -C "$INSTALL_DIR"
          rm -f "$TARBALL"

          echo "$VERSION" > "$INSTALL_DIR/.version"
          echo "Factorio Space Age $VERSION installed successfully"
        '';
      };

      # Games
      config.environment.systemPackages = with pkgs; [
        factorio-wrapper
        ghostty
        nethack
        openttd
        superTux
        tuxpaint
        wesnoth
      ];
    };
}
