rec {
  hostName = "robotnik";
  device = "c6e75505-6f53-11f0-a531-38a746309e63";

  roles = [ ];

  apps = [ ];

  aspects = [ "observable" ];

  module =
    { config, pkgs, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };

      config.sops.secrets.grimshuk-password = {
        sopsFile = ./grimshuk-password.sops;
        format = "binary";
        neededForUsers = true;
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

      # Games
      config.environment.systemPackages = with pkgs; [
        nethack
        openttd
        superTux
        tuxpaint
        wesnoth
      ];
    };
}
